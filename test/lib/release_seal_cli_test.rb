# frozen_string_literal: true

# bin/release's post-ship production smoke SEAL (step 5c) and `bin/release reseal`.
# Standalone:
#   ruby -Itest test/lib/release_seal_cli_test.rb
#
# It drives the REAL bin/release.rb in a subprocess (like release_cli_test.rb) and
# uses real git fixtures to prove WHICH tree's specs the seal runs: the ship
# workspace pinned at the frozen SHA, never the primary (rel-20260925-3b1f5c sealed
# a false red from the primary's PRE-ship specs).
#
# A NEW FILE ON PURPOSE: test/lib/release_cli_test.rb is frozen at its size by
# the suite's test-health ratchet, so the seal's cases moved here, named for their concern.
require "minitest/autorun"
require "open3"
require "tmpdir"
require "json"
require "digest"
require "fileutils"
require_relative "../support/session_env"
require_relative "../support/outbound_seams"

class ReleaseSealCliTest < Minitest::Test
  BIN = File.expand_path("../../bin/release.rb", __dir__)
  SUBPROCESS_ATTEMPTS = 3
  UNROUTABLE_API_BASE = "http://127.0.0.1:1"

  # Every bin/release lock lands in a throwaway dir (MCR_PRIMARY_LOCK_DIR moves
  # them all), so a test never flocks the live ship-workspace lock.
  def self.lock_dir
    @lock_dir ||= begin
      dir = Dir.mktmpdir("release-seal-locks")
      Minitest.after_run do
        FileUtils.remove_entry(dir)
      rescue StandardError
        nil
      end
      dir
    end
  end

  # Run bin/release.rb in a clean subprocess. SEAL_RETRY_DELAY_SECONDS=0 keeps the
  # red path's boot-window retry exercised at no wall-clock cost; OutboundSeams
  # stubs gh/heroku/op on PATH so a missed stub cannot reach the outside world.
  def run_cli(argv, call:, setup: "")
    script = %(ARGV.replace(#{argv.inspect}); load #{BIN.inspect}; #{setup}; #{call})
    env = OutboundSeams.env(
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
    flunk "bin/release subprocess exited nonzero (exit=#{last[:status].exitstatus.inspect}):\n" \
          "stdout=#{last[:out].inspect}\nstderr:\n#{last[:err]}"
  end

  # --- production smoke seal: cwd-anchored + genuinely NON-BLOCKING ------------
  # rel-20260705-8fe04b partial ship: `bin/release ship` run from the projects
  # root (not the hub checkout) reached step 5c, where the seal invoked a bare
  # CWD-RELATIVE `bin/prod-smoke` — Open3.capture2e RAISES Errno::ENOENT on an
  # unresolvable path (it never returns ok=false), so the "non-blocking SEAL"
  # aborted the ship AFTER the prod deploy but BEFORE step 6's Conductor.ship!,
  # stranding the board at `assembled`. Two guarantees under test:
  #   1. the smoke invocation is ANCHORED to a resolved tree — cwd-independent,
  #      like every other repo-scoped command in this CLI. Since
  #      rel-20260925-3b1f5c that tree is the SHIP WORKSPACE pinned at the
  #      frozen SHA, never the primary (see the git-fixture cases below);
  #   2. an unresolvable/missing script never raises out of the seal — the
  #      documented "alerts but never aborts the ship" contract. It records
  #      UNSEALED (the shipped specs never ran), not a red seal: a red seal says
  #      prod is broken, and specs that never ran say nothing about prod.

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

  # The seal's tree is resolved by resolve_seal_tree (pin + judge, under the ship
  # workspace lock); these cases stub it to a runnable shipped tree so they test
  # the run-and-record half alone. The real pin is covered by the git-fixture
  # cases below.
  SHIPPED_TREE = "/srv/projects/mcritchie-studio/.worktrees/_ship".freeze
  SEAL_TREE_STUB = <<~RUBY
    def with_ship_workspace(_repo) = yield
    def resolve_seal_tree(_frozen) = Release::SealTree::Verdict.new(root: #{SHIPPED_TREE.inspect}, reason: nil)
  RUBY

  def test_seal_anchors_prod_smoke_to_the_shipped_tree
    setup = SEAL_STUB + SEAL_TREE_STUB + <<~'RUBY'
      def sh(*a, capture: false, chdir: nil)
        $stdout.puts("SMOKE-CHDIR #{chdir.inspect}") if a[0] == "bin/prod-smoke"
        ["", true]
      end
    RUBY
    out = run_cli(["--yes"], setup: setup,
                  call: "production_smoke_seal(#{SEAL_ARGS}); puts('SEAL-RETURNED')")

    assert_includes out, %(SMOKE-CHDIR #{SHIPPED_TREE.inspect}),
                     "the smoke runs from the shipped tree, never the primary or the caller's cwd"
    assert_includes out, "SEAL-RETURNED"
  end

  # A script that could not EXECUTE (Open3 raises SystemCallError; it never returns
  # ok=false) means the shipped specs never ran — UNSEALED, not red, and never an
  # uncaught exception out of the non-blocking seal.
  def test_seal_records_unsealed_when_the_smoke_cannot_execute_not_a_red_seal
    setup = SEAL_STUB + SEAL_TREE_STUB + <<~'RUBY'
      def record_release_event(slug, step, status, attrs = {})
        $stdout.puts("EVENT #{step}:#{status} #{attrs[:message]}")
        $stdout.puts("EVENT-METADATA #{attrs[:metadata].inspect}")
      end
      def sh(*a, capture: false, chdir: nil)
        raise Errno::ENOENT, "bin/prod-smoke" if a[0] == "bin/prod-smoke"
        ["", true]
      end
    RUBY
    out = run_cli(["--yes"], setup: setup,
                  call: "begin; p(production_smoke_seal(#{SEAL_ARGS})); rescue SystemCallError => e; puts('RAISED: ' + e.class.name); end")

    refute_includes out, "RAISED:", "the seal is non-blocking by contract — no uncaught SystemCallError"
    assert_includes out, %("unsealed"), "the seal returns unsealed for the G4 gate"
    # An unsealed run is COMPLETED with seal: unsealed, never FAILED: the board and the
    # duration readers count a failed prod_smoke as a failure, and nothing failed.
    assert_includes out, "EVENT prod_smoke:completed unsealed: could not run the shipped specs",
                    "the release event records WHY it is unsealed"
    assert_match(/EVENT-METADATA \{"seal"\s*=>\s*"unsealed"\}/, out) # Hash#inspect spacing varies by ruby
    refute_includes out, "EVENT prod_smoke:failed", "an unsealed run is not a failed one"
    refute(out.lines.any? { |l| l.start_with?("SEAL-WRITE") && l.include?("record_smoke_seal!") },
           "no red seal is written for specs that never ran")
    refute_includes out, "PRODUCTION SMOKE SEAL FAILED"
    refute_includes out, "heroku rollback", "nothing says prod is broken, so no rollback prompt"
    assert_includes out, "bin/release reseal rel-seal", "the operator is handed the re-seal"
  end

  # [integration] Through the REAL record_release_event: the conductor snippet it
  # builds records a completed prod_smoke event carrying metadata seal: unsealed.
  def test_unsealed_event_reaches_the_conductor_as_completed_with_its_seal
    setup = <<~'RUBY'
      def conductor(ruby, read_only: false)
        $stdout.puts("SEAL-WRITE " + ruby.gsub("\n", " "))
        {}
      end
      def with_ship_workspace(_repo) = yield
      def resolve_seal_tree(_frozen) = Release::SealTree.refuse("the ship workspace is missing")
    RUBY
    out = run_cli(["--yes"], setup: setup, call: "p(production_smoke_seal(#{SEAL_ARGS}))")

    event = out.lines.find { |l| l.start_with?("SEAL-WRITE") && l.include?("rel-seal:prod_smoke:unsealed") }
    assert event, "the unsealed event is written:\n#{out}"
    assert_includes event, %(step: "prod_smoke", status: "completed")
    assert_match(/metadata: \{"seal"\s*=>\s*"unsealed"\}/, event)
  end

  def test_seal_green_run_records_green_and_prints_no_rollback
    setup = SEAL_STUB + SEAL_TREE_STUB + <<~'RUBY'
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
    # The SHIPPED specs RAN and failed (ok=false, no raise): that is a real red —
    # red seal, "see ship log" summary, rollback guidance, normal return.
    setup = SEAL_STUB + SEAL_TREE_STUB + <<~'RUBY'
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

  # [integration] A seal that cannot resolve the shipped tree records unsealed —
  # the refusal reason reaches the log, and the primary is never the fallback.
  def test_seal_unrunnable_tree_is_unsealed_and_never_falls_back_to_the_primary
    setup = SEAL_STUB + <<~'RUBY'
      def with_ship_workspace(_repo) = yield
      def resolve_seal_tree(_frozen) = Release::SealTree.refuse("the ship workspace is missing")
      def sh(*a, capture: false, chdir: nil)
        $stdout.puts("SMOKE-RAN #{chdir}") if a[0] == "bin/prod-smoke"
        ["", true]
      end
    RUBY
    out = run_cli(["--yes"], setup: setup, call: "p(production_smoke_seal(#{SEAL_ARGS}))")

    refute_includes out, "SMOKE-RAN", "no smoke runs at all — least of all from the primary"
    assert_includes out, "unsealed: could not run the shipped specs — the ship workspace is missing"
    assert_includes out, %("unsealed")
  end

  # --- REGRESSION (rel-20260925-3b1f5c): the seal ran the PRE-ship specs --------
  # The seal ran bin/prod-smoke from the hub PRIMARY, which still held the
  # pre-ship tree, so it smoked the OLD e2e specs against the NEW prod and
  # recorded a false red. The seal must run the FROZEN ship tree — the ship
  # workspace pinned at ship_sha[APP] — never the primary.
  #
  # A real git fixture: the primary sits at OLD, the frozen ship SHA is NEW, and
  # each commit's bin/prod-smoke prints which specs it is.
  def seal_git_fixture(dir)
    hub = File.join(dir, "mcritchie-studio")
    git = ->(*a) { system("git", "-C", hub, "-c", "user.email=t@t", "-c", "user.name=t", *a, out: File::NULL, err: File::NULL) || flunk("git #{a.join(' ')} failed") }
    FileUtils.mkdir_p(File.join(hub, "bin"))
    FileUtils.mkdir_p(File.join(hub, "node_modules", ".bin"))
    system("git", "init", "-q", "-b", "main", hub, out: File::NULL, err: File::NULL) || flunk("git init failed")
    playwright = File.join(hub, "node_modules", ".bin", "playwright")
    File.write(playwright, "#!/usr/bin/env sh\nexit 0\n")
    File.chmod(0o755, playwright)
    # Deps already installed from THIS lockfile: the stamp matches, so no npm ci.
    File.write(File.join(hub, "package-lock.json"), "{}\n")
    File.write(File.join(hub, "node_modules", ".seal-package-lock.sha256"), "#{Digest::SHA256.hexdigest("{}\n")}\n")
    script = File.join(hub, "bin", "prod-smoke")
    shas = %w[OLD NEW].map do |label|
      File.write(script, "#!/usr/bin/env sh\necho SPECS-#{label}\nexit #{label == 'OLD' ? 1 : 0}\n")
      File.chmod(0o755, script)
      git.call("add", "-A")
      git.call("commit", "-q", "-m", label)
      `git -C #{hub} rev-parse HEAD`.strip
    end
    git.call("checkout", "-q", shas.first) # the primary still holds the PRE-ship tree
    [hub, shas.first, shas.last]
  end

  def test_seal_runs_the_frozen_ship_trees_specs_not_the_primarys
    Dir.mktmpdir do |dir|
      hub, old_sha, new_sha = seal_git_fixture(dir)
      setup = SEAL_STUB + %(def repo_path(_repo) = #{hub.inspect}\n)
      args = %([{ "repo" => "mcritchie-studio" }], { "mcritchie-studio" => #{new_sha.inspect} }, "rel-seal")
      # From a FOREIGN cwd (rel-20260705-8fe04b ran the ship from the projects root).
      out = run_cli(["--yes"], setup: setup, call: "Dir.chdir(#{dir.inspect}); p(production_smoke_seal(#{args}))")

      assert_includes out, "SPECS-NEW", "the seal must run the specs of the tree that SHIPPED"
      refute_includes out, "SPECS-OLD", "never the primary's pre-ship specs (the false red of rel-20260925-3b1f5c)"
      assert_equal new_sha, `git -C #{File.join(hub, ".worktrees", "_ship")} rev-parse HEAD`.strip,
                   "the specs ran from the ship workspace pinned at the frozen SHA"
      assert_equal old_sha, `git -C #{hub} rev-parse HEAD`.strip, "the primary is never touched"
      seal_write = out.lines.find { |l| l.start_with?("SEAL-WRITE") && l.include?("record_smoke_seal!") }
      assert seal_write, "the green verdict is recorded"
      assert_includes seal_write, "passed: true"
    end
  end

  # [integration] A frozen SHA the repo does not have cannot be pinned: the real
  # ship_workspace! abort!s, and the seal turns that into UNSEALED — no smoke from
  # the primary, no red seal, and a normal return.
  def test_seal_unpinnable_frozen_sha_is_unsealed_across_the_real_pin
    Dir.mktmpdir do |dir|
      hub, old_sha, _new = seal_git_fixture(dir)
      setup = SEAL_STUB + %(def repo_path(_repo) = #{hub.inspect}\n)
      args = %([{ "repo" => "mcritchie-studio" }], { "mcritchie-studio" => #{('f' * 40).inspect} }, "rel-seal")
      out = run_cli(["--yes"], setup: setup, call: "p(production_smoke_seal(#{args}))")

      refute_includes out, "SPECS-", "no specs ran — not the primary's, not anyone's"
      assert_includes out, "unsealed: could not run the shipped specs — could not pin the ship workspace at fffffff"
      assert_includes out, %("unsealed")
      refute(out.lines.any? { |l| l.start_with?("SEAL-WRITE") && l.include?("record_smoke_seal!") })
      assert_equal old_sha, `git -C #{hub} rev-parse HEAD`.strip, "the primary is never touched"
    end
  end

  # Commit one more change on top of the fixture's NEW and return its SHA.
  def seal_fixture_commit(hub, *rm_paths)
    system("git", "-C", hub, "checkout", "-q", "main", out: File::NULL, err: File::NULL) || flunk("checkout")
    system("git", "-C", hub, "rm", "-rq", *rm_paths, out: File::NULL, err: File::NULL) || flunk("git rm")
    system("git", "-C", hub, "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "-m", "drop",
           out: File::NULL, err: File::NULL) || flunk("commit")
    `git -C #{hub} rev-parse HEAD`.strip
  end

  # [integration] A shipped tree with no bin/prod-smoke is unsealed, never red.
  def test_seal_shipped_tree_without_the_script_is_unsealed_not_red
    Dir.mktmpdir do |dir|
      hub, = seal_git_fixture(dir)
      gone = seal_fixture_commit(hub, "bin/prod-smoke")
      setup = SEAL_STUB + %(def repo_path(_repo) = #{hub.inspect}\n)
      args = %([{ "repo" => "mcritchie-studio" }], { "mcritchie-studio" => #{gone.inspect} }, "rel-seal")
      out = run_cli(["--yes"], setup: setup, call: "p(production_smoke_seal(#{args}))")

      assert_includes out, "unsealed: could not run the shipped specs — the shipped tree has no bin/prod-smoke"
      refute_includes out, "PRODUCTION SMOKE SEAL FAILED"
      refute_includes out, "heroku rollback"
    end
  end

  # [integration] A ship workspace with no playwright runner: the deps install is
  # aimed at the workspace, and when it leaves no runner the seal is unsealed.
  def test_seal_workspace_without_playwright_is_unsealed_not_red
    Dir.mktmpdir do |dir|
      hub, = seal_git_fixture(dir)
      bare = seal_fixture_commit(hub, "node_modules")
      setup = SEAL_STUB + %(def repo_path(_repo) = #{hub.inspect}\n) +
              %(def ensure_seal_playwright!(path) = $stdout.puts("NPM-CI " + path)\n)
      args = %([{ "repo" => "mcritchie-studio" }], { "mcritchie-studio" => #{bare.inspect} }, "rel-seal")
      out = run_cli(["--yes"], setup: setup, call: "p(production_smoke_seal(#{args}))")

      assert_includes out, "NPM-CI #{File.join(hub, '.worktrees', '_ship')}", "the deps install targets the ship workspace"
      assert_includes out, "playwright is not installed in the ship workspace"
      refute_includes out, "SPECS-", "the smoke never ran without its runner"
      refute_includes out, "PRODUCTION SMOKE SEAL FAILED"
    end
  end

  # --- the seal's npm ci: skipped when current, re-run on a new lockfile, bounded
  # Review of PR #1605: node_modules survives the workspace's `git clean -fd`, so
  # a ship that bumps @playwright/test would run on stale deps and seal a false
  # red; and an unbounded npm ci would stall the ship after prod deployed. A fake
  # npm stands in for the real one (seal_npm_ci_cmd is the seam).
  def fake_npm(dir, body)
    path = File.join(dir, "fake-npm")
    File.write(path, "#!/usr/bin/env sh\n#{body}\n")
    File.chmod(0o755, path)
    path
  end

  def test_seal_skips_npm_ci_when_the_installed_deps_match_the_shipped_lockfile
    Dir.mktmpdir do |dir|
      hub, _old, new_sha = seal_git_fixture(dir)
      ran = File.join(dir, "npm-ran")
      npm = fake_npm(dir, "touch #{ran}")
      setup = SEAL_STUB + %(def repo_path(_repo) = #{hub.inspect}\ndef seal_npm_ci_cmd = [#{npm.inspect}]\n)
      args = %([{ "repo" => "mcritchie-studio" }], { "mcritchie-studio" => #{new_sha.inspect} }, "rel-seal")
      out = run_cli(["--yes"], setup: setup, call: "p(production_smoke_seal(#{args}))")

      refute File.exist?(ran), "current deps are reused — the warm workspace stays warm"
      refute_includes out, "installing the shipped tree's node deps"
      assert_includes out, "SPECS-NEW"
      assert_includes out, %("green")
    end
  end

  def test_seal_reinstalls_deps_when_the_shipped_lockfile_changed
    Dir.mktmpdir do |dir|
      hub, = seal_git_fixture(dir)
      # The ship bumps the lockfile (a Playwright upgrade); the stamp still names the old one.
      system("git", "-C", hub, "checkout", "-q", "main", out: File::NULL, err: File::NULL) || flunk("checkout")
      File.write(File.join(hub, "package-lock.json"), %({"playwright":"2"}\n))
      system("git", "-C", hub, "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-qam", "bump",
             out: File::NULL, err: File::NULL) || flunk("commit")
      bumped = `git -C #{hub} rev-parse HEAD`.strip
      ran = File.join(dir, "npm-ran")
      npm = fake_npm(dir, "pwd > #{ran}")
      setup = SEAL_STUB + %(def repo_path(_repo) = #{hub.inspect}\ndef seal_npm_ci_cmd = [#{npm.inspect}]\n)
      args = %([{ "repo" => "mcritchie-studio" }], { "mcritchie-studio" => #{bumped.inspect} }, "rel-seal")
      out = run_cli(["--yes"], setup: setup, call: "p(production_smoke_seal(#{args}))")

      ship = File.realpath(File.join(hub, ".worktrees", "_ship"))
      assert File.exist?(ran), "a changed lockfile re-runs npm ci"
      assert_equal ship, File.realpath(File.read(ran).strip), "…in the ship workspace"
      assert_includes out, "installing the shipped tree's node deps"
      assert_includes out, "SPECS-NEW", "…and then the shipped specs run"
      assert_includes out, %("green")
      assert_equal Digest::SHA256.hexdigest(%({"playwright":"2"}\n)),
                   File.read(File.join(ship, "node_modules", ".seal-package-lock.sha256")).strip,
                   "the stamp now names the lockfile it installed from"
    end
  end

  def test_seal_failed_reinstall_is_unsealed_not_a_stale_red
    Dir.mktmpdir do |dir|
      hub, = seal_git_fixture(dir)
      system("git", "-C", hub, "checkout", "-q", "main", out: File::NULL, err: File::NULL) || flunk("checkout")
      File.write(File.join(hub, "package-lock.json"), %({"playwright":"2"}\n))
      system("git", "-C", hub, "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-qam", "bump",
             out: File::NULL, err: File::NULL) || flunk("commit")
      bumped = `git -C #{hub} rev-parse HEAD`.strip
      npm = fake_npm(dir, "echo offline; exit 1")
      setup = SEAL_STUB + %(def repo_path(_repo) = #{hub.inspect}\ndef seal_npm_ci_cmd = [#{npm.inspect}]\n)
      args = %([{ "repo" => "mcritchie-studio" }], { "mcritchie-studio" => #{bumped.inspect} }, "rel-seal")
      out = run_cli(["--yes"], setup: setup, call: "p(production_smoke_seal(#{args}))")

      refute_includes out, "SPECS-", "the specs never run on deps that do not match the shipped lockfile"
      assert_includes out, "node deps do not match the shipped package-lock.json"
      assert_includes out, %("unsealed")
    end
  end

  def test_seal_npm_ci_that_hangs_times_out_and_records_unsealed
    Dir.mktmpdir do |dir|
      hub, = seal_git_fixture(dir)
      system("git", "-C", hub, "checkout", "-q", "main", out: File::NULL, err: File::NULL) || flunk("checkout")
      File.write(File.join(hub, "package-lock.json"), %({"playwright":"2"}\n))
      system("git", "-C", hub, "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-qam", "bump",
             out: File::NULL, err: File::NULL) || flunk("commit")
      bumped = `git -C #{hub} rev-parse HEAD`.strip
      npm = fake_npm(dir, "sleep 30")
      setup = SEAL_STUB + %(ENV["SEAL_NPM_CI_TIMEOUT_SECONDS"] = "1"\n) +
              %(def repo_path(_repo) = #{hub.inspect}\ndef seal_npm_ci_cmd = [#{npm.inspect}]\n)
      args = %([{ "repo" => "mcritchie-studio" }], { "mcritchie-studio" => #{bumped.inspect} }, "rel-seal")
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      out = run_cli(["--yes"], setup: setup, call: "p(production_smoke_seal(#{args}))")
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

      assert_operator elapsed, :<, 20, "the hung install is killed at the limit, not waited out"
      assert_includes out, "unsealed: could not run the shipped specs — npm ci timed out after 1s in the ship workspace"
      refute_includes out, "SPECS-"
      assert_includes out, %("unsealed")
    end
  end

  # The timeout must kill npm's whole PROCESS GROUP. npm ci runs node children; a
  # kill aimed at the npm pid alone leaves them running in the ship workspace,
  # holding the lock's tree and the output pipe (Carl, review of PR #1605: every
  # other seal test passed with `Process.kill("TERM", pid)` in place of `-pid`).
  # The fake npm spawns a child that spawns a sleeper — the grandchild a
  # pid-only kill orphans — and records the sleeper's pid.
  def test_npm_ci_timeout_kills_the_whole_process_group_not_just_npm
    Dir.mktmpdir do |dir|
      sleeper_pid = File.join(dir, "sleeper.pid")
      npm = fake_npm(dir, %(sh -c 'sleep 30 & echo $! > #{sleeper_pid}; wait' &\nwait))
      call = <<~RUBY
        _out, ok, timed_out = sh_bounded(#{npm.inspect}, chdir: #{dir.inspect}, timeout: 1)
        puts("TIMED-OUT " + timed_out.inspect + " OK " + ok.inspect)
        pid = File.read(#{sleeper_pid.inspect}).to_i
        alive = true
        20.times do
          begin
            Process.kill(0, pid)
          rescue Errno::ESRCH
            alive = false
            break
          end
          sleep 0.1
        end
        puts(alive ? "ORPHAN-ALIVE " + pid.to_s : "ORPHAN-DEAD")
      RUBY
      out = run_cli(["--yes"], call: call)

      assert_includes out, "TIMED-OUT true OK false"
      assert_includes out, "ORPHAN-DEAD", "the timeout must signal npm's process GROUP, not only npm's pid:\n#{out}"
    ensure
      pid = File.read(sleeper_pid).to_i if sleeper_pid && File.exist?(sleeper_pid)
      Process.kill("KILL", pid) if pid&.positive? rescue Errno::ESRCH
    end
  end

  # --- bin/release reseal: re-seal an already-shipped release ------------------
  # [integration] The false-red release (rel-20260925-3b1f5c) was sealed from the
  # primary's pre-ship specs. `bin/release reseal <slug>` reads the release, pins
  # the ship workspace at ITS frozen hub SHA, runs those specs, and overwrites the
  # recorded seal — with a summary that says it was re-sealed.
  def reseal_stub(hub, state: "shipped", sha:, superseded_by: nil)
    release = { "slug" => "rel-old", "state" => state, "deployed_sha" => sha,
                "repos" => [{ "repo" => "mcritchie-studio", "kind" => "app" }],
                "qa_shas" => { "mcritchie-studio" => sha },
                "seal" => "🔴 Production smoke seal: FAILED — see ship log", "superseded_by" => superseded_by }
    <<~RUBY
      def repo_path(_repo) = #{hub.inspect}
      def record_release_event(slug, step, status, attrs = {})
        $stdout.puts("EVENT \#{step}:\#{status}")
      end
      def conductor(ruby, read_only: false)
        return JSON.parse(#{release.to_json.inspect}) if read_only
        $stdout.puts("SEAL-WRITE " + ruby.gsub("\n", " "))
        {}
      end
    RUBY
  end

  def test_reseal_runs_the_releases_shipped_specs_and_overwrites_its_seal
    Dir.mktmpdir do |dir|
      hub, old_sha, new_sha = seal_git_fixture(dir)
      out = run_cli(["--yes"], setup: reseal_stub(hub, sha: new_sha, superseded_by: "rel-new"),
                    call: %(Dir.chdir(#{dir.inspect}); ARGV.replace(["rel-old"]); reseal(Release::Cli.positional_slugs(ARGV).first)))

      assert_includes out, "current seal: 🔴", "the operator sees the seal being replaced"
      assert_includes out, "SPECS-NEW", "the release's own shipped specs ran"
      refute_includes out, "SPECS-OLD"
      seal_write = out.lines.find { |l| l.start_with?("SEAL-WRITE") && l.include?("record_smoke_seal!") }
      assert seal_write, "the re-seal overwrites the recorded seal"
      assert_includes seal_write, %(Release.find_by!(slug: "rel-old"))
      assert_includes seal_write, "passed: true"
      assert_includes seal_write, "re-sealed from the shipped tree; prod has since moved to rel-new"
      refute_includes out, "EVENT prod_smoke:started", "a re-seal does not re-open the ship's seal step"
      assert_includes out, "rel-old re-sealed: green"
      assert_equal old_sha, `git -C #{hub} rev-parse HEAD`.strip, "the primary is never touched"
    end
  end

  # [integration] The ship closed G4 with metadata.seal; a re-seal re-stamps it, or
  # the /deployments G4 column keeps the verdict the re-seal just replaced.
  def test_reseal_restamps_the_g4_gates_seal
    Dir.mktmpdir do |dir|
      hub, _old, new_sha = seal_git_fixture(dir)
      out = run_cli(["--yes"], setup: reseal_stub(hub, sha: new_sha), call: %(reseal("rel-old")))

      gate_write = out.lines.find { |l| l.start_with?("SEAL-WRITE") && l.include?("GateRun.restamp_seal!") }
      assert gate_write, "the re-seal re-stamps G4's seal:\n#{out}"
      assert_includes gate_write, %(subject_slug: "rel-old")
      assert_includes gate_write, %(seal: "green")
    end
  end

  # [integration] A re-seal that could not run leaves G4's seal as it was — the same
  # rule the release's own recorded seal follows.
  def test_an_unsealed_reseal_leaves_the_g4_seal_alone
    Dir.mktmpdir do |dir|
      hub, = seal_git_fixture(dir)
      gone = seal_fixture_commit(hub, "bin/prod-smoke")
      out = run_cli(["--yes"], setup: reseal_stub(hub, sha: gone), call: %(reseal("rel-old")))

      assert_includes out, "re-sealed: unsealed"
      refute_includes out, "GateRun.restamp_seal!", "nothing was judged, so nothing is re-stamped"
    end
  end

  def test_reseal_refuses_a_release_that_has_not_shipped
    Dir.mktmpdir do |dir|
      hub, _old, new_sha = seal_git_fixture(dir)
      out = run_cli(["--yes"], setup: reseal_stub(hub, state: "assembled", sha: new_sha),
                    call: %(begin; reseal("rel-old"); rescue SystemExit => e; puts("ABORTED: " + e.message); end))

      assert_includes out, "ABORTED"
      assert_includes out, "not shipped"
      refute_includes out, "SPECS-", "nothing ran"
      refute_includes out, "SEAL-WRITE"
    end
  end

  def test_reseal_needs_a_release_slug
    out = run_cli(["--yes"], call: %(begin; reseal(nil); rescue SystemExit => e; puts("ABORTED: " + e.message); end))
    assert_includes out, "ABORTED"
    assert_includes out, "bin/release reseal <release-slug>"
  end

  def test_reseal_dry_run_previews_without_running_or_recording
    Dir.mktmpdir do |dir|
      hub, _old, new_sha = seal_git_fixture(dir)
      out = run_cli(["--dry-run"], setup: reseal_stub(hub, sha: new_sha), call: %(reseal("rel-old")))

      assert_includes out, "re-seal from the mcritchie-studio ship workspace at #{new_sha[0, 7]}"
      assert_includes out, "DRY RUN"
      refute_includes out, "SPECS-"
      refute_includes out, "SEAL-WRITE"
    end
  end
end
