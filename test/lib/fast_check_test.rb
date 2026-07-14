# frozen_string_literal: true

# Harness tests for bin/fast-check — the G1 FAST cert runner (diff-mapped tests
# + core spine + rubocop on changed files, recording "[fast-cert@<fp>]"
# fingerprint-bound evidence). Mirrors test/lib/full_suite_check_test.rb's seam
# pattern: the script is shelled with its lanes stubbed via FAST_CHECK_* env vars
# against throwaway git repos, so the ORCHESTRATION is exercised without a real
# Rails run; the board/gate CLIs are stubbed via FAST_CHECK_TASK_BIN /
# FAST_CHECK_GATE_BIN so the durable-record writes are asserted without a board.
# Selection logic itself is unit-tested in test/lib/fast_cert_test.rb.
# Run directly:
#   ruby -Itest test/lib/fast_check_test.rb
# Also picked up by the normal `bin/rails test` sweep.

require "minitest/autorun"
require "json"
require "tmpdir"
require "fileutils"
require "rbconfig"
require "shellwords"
require_relative "../support/session_env"
require_relative "../../bin/lib/full_suite_gate"

class FastCheckTest < Minitest::Test
  BIN = File.expand_path("../../bin/fast-check", __dir__)
  DOR = File.expand_path("../../bin/dor-check", __dir__)

  # --- [unit] merge_evidence with lanes: the fast writer must not drop full evidence

  def test_fast_lane_merge_replaces_only_prior_fast_cert_lines
    existing = [
      "[unit] bin/rails test test/foo_test.rb",
      "[full-suite@fullfp] tests green",
      "[rubocop@fullfp] lint clean",
      "[fast-cert@oldfp] stale fast cert",
      "[full-suite-bypass] tracked elsewhere"
    ]
    merged = FullSuiteGate.merge_evidence(existing, ["[fast-cert@newfp] fresh"],
                                          lanes: [FullSuiteGate::FAST_LANE])

    assert_includes merged, "[unit] bin/rails test test/foo_test.rb"
    assert_includes merged, "[full-suite@fullfp] tests green", "full evidence must survive a fast write"
    assert_includes merged, "[rubocop@fullfp] lint clean"
    assert_includes merged, "[full-suite-bypass] tracked elsewhere"
    assert_includes merged, "[fast-cert@newfp] fresh"
    refute_includes merged, "[fast-cert@oldfp] stale fast cert"
  end

  def test_default_merge_supersedes_only_the_lanes_supplied
    # The write rule (lib/cert_evidence.rb): a writer supersedes exactly the lanes
    # it SUPPLIES evidence for. bin/full-suite-check stamps full-suite + rubocop,
    # so those lanes are replaced and a prior fast-cert line is carried over — it
    # used to be deleted, but the board now preserves any lane a write does not
    # address (that is what stops `--checks` from wiping a cert), so deleting it
    # here would only make the CLI disagree with what the board stores. The lingering
    # line is inert: `ok` is graded off LANES (full-suite + rubocop) alone.
    merged = FullSuiteGate.merge_evidence(["[fast-cert@oldfp] x"], ["[full-suite@newfp] y"])
    assert_includes merged, "[fast-cert@oldfp] x"
    assert_includes merged, "[full-suite@newfp] y"
  end

  def test_evaluate_grades_the_fast_lane_alongside_the_full_lanes
    checks = ["[fast-cert@abc1234] fast green"]
    assert_equal :fresh, FullSuiteGate.lane_status(checks, FullSuiteGate::FAST_LANE, "abc1234")
    assert_equal :stale, FullSuiteGate.lane_status(checks, FullSuiteGate::FAST_LANE, "fffffff")
    assert_equal :missing, FullSuiteGate.lane_status([], FullSuiteGate::FAST_LANE, "abc1234")
  end

  # --- fixtures --------------------------------------------------------------------

  # A temp git repo shaped like an app: a changed model + its convention test, a
  # spine test + spine config, and one committed baseline. Yields the dir.
  # `subpath:` puts the repo somewhere specific under the temp dir — e.g.
  # ".worktrees/<slug>", which is what makes it read as an agent DESK (DeskGuard).
  def with_repo(subpath: nil)
    Dir.mktmpdir do |tmp|
      dir = subpath ? File.join(tmp, subpath) : tmp
      FileUtils.mkdir_p(dir)
      git = ->(args) { assert(system("git -C #{dir} #{args} >/dev/null 2>&1"), "git #{args}") }
      write = lambda do |rel, body|
        full = File.join(dir, rel)
        FileUtils.mkdir_p(File.dirname(full))
        File.write(full, body)
      end
      write.call("app/models/base.rb", "class Base; end\n")
      write.call("test/models/widget_test.rb", "widget test\n")
      write.call("test/models/spine_core_test.rb", "spine test\n")
      write.call("spine.yml", "spine:\n  - test/models/spine_core_test.rb\n")
      write_repo_shape(dir, subpath)
      # The harness writes its stub CLIs and their log INTO the repo dir, so without
      # this they read as untracked dirt to the dirty-tree guard (cert_tree_guard.rb)
      # — test tooling, not uncommitted work. Ignoring them keeps the fixture's dirt
      # HONEST: the only uncommitted file is the branch diff itself (widget.rb below).
      write.call(".gitignore", "stub.log\n*-stub\n")
      git.call("init -q")
      git.call("config user.email tester@example.com")
      git.call("config user.name tester")
      git.call("add -A")
      git.call("commit -q -m init")
      # The branch diff: a changed model that maps to test/models/widget_test.rb.
      write.call("app/models/widget.rb", "class Widget; end\n")
      yield dir, write
    end
  end

  # Make the fixture REPO-SHAPED, because the desk guard no longer reads a file — it BOOTS
  # THE APP and reads back the database it actually connects to (bin/lib/desk_guard.rb).
  # A desk fixture therefore needs the two things a real desk has:
  #
  #   * the REPO's config/database.yml — one level up from <repo>/.worktrees/<slug> — which
  #     is where the SHARED test database name is read from (ERB-stripped, so no env var can
  #     rewrite the value the resolution is compared against); and
  #   * a `bin/rails` to boot. The shim answers with DESK_DB_STUB, so each test STATES what
  #     the booted app would resolve to, and defaults to the SHARED name — the hazard.
  def write_repo_shape(dir, subpath)
    repo_root = subpath ? File.expand_path("../..", dir) : dir
    FileUtils.mkdir_p(File.join(repo_root, "config"))
    File.write(File.join(repo_root, "config", "database.yml"), <<~YAML)
      default: &default
        adapter: postgresql
      test:
        <<: *default
        database: studio_test
    YAML

    FileUtils.mkdir_p(File.join(dir, "bin"))
    shim = File.join(dir, "bin", "rails")
    File.write(shim, "#!/bin/sh\necho \"DESKDB=${DESK_DB_STUB:-studio_test}\"\n")
    File.chmod(0o755, shim)
  end

  # A stub CLI: appends "<MARKER>\t<argv...>" to STUB_LOG_<MARKER>; exits 1 when
  # FAIL_TOKEN is set and appears in its argv, else 0. For the TASK stub, `show`
  # prints TASK_SHOW_JSON so the runner's read-merge-write can be exercised.
  def write_stub(dir, name, marker)
    stub = File.join(dir, name)
    File.write(stub, <<~RUBY)
      #!#{RbConfig.ruby}
      File.open(ENV.fetch("STUB_LOG"), "a") { |f| f.puts(["#{marker}", *ARGV].join("\\t")) }
      if ARGV.first == "show" && ENV["TASK_SHOW_JSON"]
        puts ENV["TASK_SHOW_JSON"]
      end
      token = ENV["FAIL_TOKEN"].to_s
      exit(!token.empty? && ARGV.join(" ").include?(token) ? 1 : 0)
    RUBY
    FileUtils.chmod("+x", stub)
    stub
  end

  # Run bin/fast-check against `dir` with every seam stubbed. Returns
  # [stdout, exitcode, log_lines] where log_lines is the parsed stub log
  # ([[marker, argv...], ...] in call order).
  #
  # implicit_root: true drops the FAST_CHECK_ROOT override and runs the script
  # WITH `dir` as its cwd instead — the root resolves from the cwd git toplevel,
  # exercising the task-root guard (which an explicit override bypasses). stderr
  # is merged into stdout there so the refusal message is assertable.
  def run_check(dir, args: ["--print"], fail_token: "", extra_env: {}, implicit_root: false)
    log = File.join(dir, "stub.log")
    lane = write_stub(dir, "lane-stub", "LANE")
    gate = write_stub(dir, "gate-stub", "GATE")
    task = write_stub(dir, "task-stub", "TASK")
    # SessionEnv.neutralized: the child must name NO agent session — bin/fast-check
    # shells to bin/task and the gate. See test/support/session_env.rb.
    env = SessionEnv.neutralized({
      "FAST_CHECK_ROOT" => dir,
      "FAST_CHECK_DIFF_BASE" => "HEAD",
      "FAST_CHECK_SPINE" => File.join(dir, "spine.yml"),
      "FAST_CHECK_TEST_PREPARE_CMD" => "true",
      "FAST_CHECK_TEST_CMD" => "#{lane.shellescape} TEST",
      "FAST_CHECK_RUBOCOP_CMD" => "#{lane.shellescape} RUBOCOP",
      "FAST_CHECK_GATE_BIN" => gate,
      "FAST_CHECK_TASK_BIN" => task,
      "STUB_LOG" => log,
      "FAIL_TOKEN" => fail_token
    }.merge(extra_env))
    cmd = "#{BIN.shellescape} #{args.map(&:shellescape).join(' ')}"
    out =
      if implicit_root
        env.delete("FAST_CHECK_ROOT")
        IO.popen(env, "#{cmd} 2>&1", chdir: dir, &:read)
      else
        IO.popen(env, "#{cmd} 2>/dev/null", &:read)
      end
    code = $?.exitstatus
    lines = File.exist?(log) ? File.readlines(log, chomp: true).map { |l| l.split("\t") } : []
    [out, code, lines]
  end

  def lane_calls(lines, first_arg)
    lines.select { |l| l[0] == "LANE" && l[1] == first_arg }.map { |l| l[2..] }
  end

  # --- [unit] lanes + selection wiring ----------------------------------------------

  def test_green_run_prints_fingerprint_bound_fast_cert_evidence
    with_repo do |dir, _|
      out, code, = run_check(dir)
      assert_equal 0, code, out
      assert_match(/\A\[fast-cert@[0-9a-f]{7,64}\]/, out)
      assert_match(/full suite runs on CI/, out)
    end
  end

  def test_mapped_lane_gets_the_diff_mapped_test_and_spine_lane_gets_the_spine
    with_repo do |dir, _|
      _, code, lines = run_check(dir)
      assert_equal 0, code
      tests = lane_calls(lines, "TEST")
      assert_equal 2, tests.size, "one mapped-tests run + one spine run: #{lines.inspect}"
      assert_equal ["test/models/widget_test.rb"], tests[0], "mapped lane runs the diff-mapped test"
      assert_equal ["test/models/spine_core_test.rb"], tests[1], "spine lane runs the configured spine"
    end
  end

  def test_rubocop_lane_is_scoped_to_changed_lintable_files_only
    with_repo do |dir, _|
      _, code, lines = run_check(dir)
      assert_equal 0, code
      lint = lane_calls(lines, "RUBOCOP")
      assert_equal 1, lint.size
      assert_equal ["app/models/widget.rb"], lint[0],
                   "rubocop runs on the CHANGED file only — never the whole repo"
    end
  end

  def test_mapped_tests_already_covered_by_the_spine_run_once
    with_repo do |dir, write|
      # The diff now ALSO touches the spine-covered model: its mapped test is the
      # spine test itself, so the mapped lane must not re-run it.
      write.call("app/models/spine_core.rb", "class SpineCore; end\n")
      _, code, lines = run_check(dir)
      assert_equal 0, code
      tests = lane_calls(lines, "TEST")
      assert_equal ["test/models/widget_test.rb"], tests[0], "spine-covered mapped test dropped from the mapped lane"
      assert_equal ["test/models/spine_core_test.rb"], tests[1]
    end
  end

  def test_red_test_lane_exits_nonzero_and_records_nothing
    with_repo do |dir, _|
      out, code, = run_check(dir, fail_token: "widget_test")
      assert_equal 1, code, out
      refute_match(/\[fast-cert@/, out, "a red lane must not certify")
    end
  end

  def test_red_rubocop_lane_exits_nonzero_and_records_nothing
    with_repo do |dir, _|
      out, code, = run_check(dir, fail_token: "RUBOCOP")
      assert_equal 1, code, out
      refute_match(/\[fast-cert@/, out)
    end
  end

  def test_doc_only_diff_skips_test_and_rubocop_lanes_but_still_runs_the_spine
    with_repo do |dir, write|
      write.call("docs/notes.md", "notes\n")
      env = { "FAST_CHECK_CHANGED_FILES" => "docs/notes.md" }
      out, code, lines = run_check(dir, extra_env: env, fail_token: "RUBOCOP")
      # rubocop's stub would FAIL if invoked — a doc-only diff must skip it.
      assert_equal 0, code, out
      assert_empty lane_calls(lines, "RUBOCOP"), "no lintable files → rubocop lane skipped"
      assert_equal [["test/models/spine_core_test.rb"]], lane_calls(lines, "TEST"),
                   "the spine still runs when nothing maps"
      assert_match(/\[fast-cert@/, out)
    end
  end

  def test_test_prepare_failure_aborts_before_any_lane
    with_repo do |dir, _|
      out, code, lines = run_check(dir, extra_env: { "FAST_CHECK_TEST_PREPARE_CMD" => "false" })
      assert_equal 1, code, out
      assert_empty lane_calls(lines, "TEST"), "no lane runs against an unprepared test env"
      refute_match(/\[fast-cert@/, out)
    end
  end

  # --- [unit] the virgin-tree bundled-asset regression -------------------------------
  #
  # A fake `bin/rails` that models the two Rails behaviours this cert depends on:
  #
  #   1. `test:prepare` is the hook a CSS/JS bundler enhances to BUILD its artifact
  #      (tailwindcss-rails: `Rake::Task["test:prepare"].enhance(["tailwindcss:build"])`).
  #      NOTHING else builds it -- `db:test:prepare` does not (tailwindcss enhances it
  #      only as a FALLBACK, when test:prepare is undefined).
  #   2. Propshaft raises "The asset ... is not present in the asset pipeline" when a
  #      view's stylesheet_link_tag target was never built.
  #
  # The fake fails its `test` lane ONLY on the missing artifact -- never on the paths --
  # so the test reproduces the exact production symptom (a virgin worktree, where the
  # gitignored app/assets/builds/ holds nothing but .keep) and nothing else.
  def write_fake_rails(dir)
    rails = File.join(dir, "bin", "rails")
    FileUtils.mkdir_p(File.dirname(rails))
    File.write(rails, <<~RUBY)
      #!#{RbConfig.ruby}
      require "fileutils"
      built = File.join(Dir.pwd, "app/assets/builds/tailwind.css")
      File.open(ENV.fetch("STUB_LOG"), "a") { |f| f.puts(["RAILS", *ARGV].join("\\t")) }
      if ARGV.include?("test:prepare")
        FileUtils.mkdir_p(File.dirname(built))
        File.write(built, "/* built by the test:prepare hook */")
      end
      if ARGV.first == "test" && !File.exist?(built)
        warn 'The asset "tailwind.css" is not present in the asset pipeline.'
        exit 1
      end
      exit 0
    RUBY
    FileUtils.chmod("+x", rails)
  end

  # Regression (build-assets-on-worktree-bringup): fast-check's test lanes pass EXPLICIT
  # FILE PATHS, and Rails SKIPS its own test:prepare whenever an argument looks like a
  # path -- Rails::Command::TestCommand runs it only `if self.args.none?(
  # EXACT_TEST_ARGUMENT_PATTERN)`. So the bundler hook that an ARGLESS `bin/rails test`
  # fires for free (CI, bin/full-suite-check -- all green; the release gate workspaces
  # prep their own env since gate-workspace-skips-test-prepare, PR #522) never fires
  # here, and on a virgin worktree every
  # view-rendering test errored with
  # `The asset "tailwind.css" is not present in the asset pipeline`: ~77 red on a
  # ci.yml-only or docs-only diff. A G1 cert that reports an ENV GAP as a test
  # regression is lying, so the cert must run test:prepare ITSELF.
  #
  # Note this deliberately does NOT stub FAST_CHECK_TEST_PREPARE_CMD / FAST_CHECK_TEST_CMD
  # (a nil value UNSETS the var for the child): the DEFAULT lane commands are the thing
  # under test — the bug lived in the default.
  def test_prepare_lane_builds_bundled_assets_before_the_path_arg_test_lanes
    with_repo do |dir, _|
      write_fake_rails(dir)
      out, code, lines = run_check(dir, extra_env: {
                                     "FAST_CHECK_TEST_PREPARE_CMD" => nil, # use the real default
                                     "FAST_CHECK_TEST_CMD" => nil,         # use the real default
                                     "FAST_CHECK_RUBOCOP_CMD" => "true"
                                   })
      rails = lines.select { |l| l[0] == "RAILS" }.map { |l| l[1..] }

      assert_equal ["db:test:prepare", "test:prepare"], rails[0],
                   "the prepare lane must run Rails' test:prepare hook (which builds the bundled " \
                   "CSS) as well as the test DB prepare — the path-arg test lanes below will not"
      assert_path_exists File.join(dir, "app/assets/builds/tailwind.css"),
                         "prepare must leave the bundled asset on disk for the lanes that follow"
      assert_equal ["test", "test/models/widget_test.rb"], rails[1], "mapped lane still runs by path"
      assert_equal ["test", "test/models/spine_core_test.rb"], rails[2], "spine lane still runs by path"
      assert_equal 0, code, "a virgin tree must certify GREEN, not red on a missing asset:\n#{out}"
      assert_match(/\A\[fast-cert@/, out)
    end
  end

  def test_list_mode_prints_the_selection_without_running_anything
    with_repo do |dir, _|
      out, code, lines = run_check(dir, args: ["--list"])
      assert_equal 0, code, out
      assert_match(%r{mapped\s+test/models/widget_test\.rb}, out)
      assert_match(%r{spine\s+test/models/spine_core_test\.rb}, out)
      assert_match(%r{lint\s+app/models/widget\.rb}, out)
      assert_empty lines, "--list must not run lanes or emit gate/task writes"
    end
  end

  def test_fingerprint_matches_dor_check_view
    # The writer and the reader must agree, or fast-cert evidence never validates.
    with_repo do |dir, _|
      out, = run_check(dir)
      runner_fp = out[/@([0-9a-f]{7,64})\]/, 1]
      dor_fp = IO.popen(SessionEnv.neutralized("DOR_CHECK_DIFF_ROOT" => dir),
                        "#{DOR} --suite-fingerprint 2>/dev/null", &:read).strip
      assert_equal dor_fp, runner_fp
    end
  end

  # --- [integration] durable-record writes: task evidence + G1 gate markers ---------

  SHOW_JSON = JSON.generate(
    "metadata" => { "devops" => { "checks_run" => [
      "[unit] bin/rails test test/models/widget_test.rb",
      "[full-suite@fullfp] tests green",
      "[fast-cert@oldfp] prior fast cert"
    ] } }
  )

  def test_recording_merges_evidence_preserving_tiers_and_full_cert_lines
    with_repo do |dir, _|
      out, code, lines = run_check(dir, args: ["task-x"], extra_env: { "TASK_SHOW_JSON" => SHOW_JSON })
      assert_equal 0, code, out

      update = lines.find { |l| l[0] == "TASK" && l[1] == "update" }
      refute_nil update, "green run records evidence via task update: #{lines.inspect}"
      checks = update.each_cons(2).select { |a, _| a == "--checks" }.map(&:last)
      assert_includes checks, "[unit] bin/rails test test/models/widget_test.rb", "tier tags preserved"
      assert_includes checks, "[full-suite@fullfp] tests green", "full-cert evidence preserved"
      assert(checks.any? { |c| c =~ /\A\[fast-cert@[0-9a-f]{7,64}\]/ }, "fresh fast-cert line recorded")
      refute_includes checks.join("\n"), "[fast-cert@oldfp]", "prior fast-cert line replaced"
    end
  end

  def test_green_run_opens_g1_appends_one_sop_per_lane_and_self_closes_success
    with_repo do |dir, _|
      _, code, lines = run_check(dir, args: ["task-x"], extra_env: { "TASK_SHOW_JSON" => SHOW_JSON })
      assert_equal 0, code
      gate = lines.select { |l| l[0] == "GATE" }
      assert_equal %w[open sop sop sop sop close], gate.map { |l| l[1] },
                   "open + one sop per lane + a self-close on green (cert owns g1_cert now, " \
                   "not dor-check): #{gate.inspect}"
      sop_names = gate.select { |l| l[1] == "sop" }.map { |l| l[l.index("--sop") + 1] }
      assert_equal %w[test-prepare mapped-tests spine rubocop-changed], sop_names
      close = gate.find { |l| l[1] == "close" }
      assert_includes close, "--success", "the green cert closes g1_cert success itself"
      assert(gate.all? { |l| l[2] == "task" && l[3] == "task-x" && l[4] == "g1_cert" })
    end
  end

  def test_red_lane_closes_g1_failed
    with_repo do |dir, _|
      _, code, lines = run_check(dir, args: ["task-x"], fail_token: "widget_test",
                                      extra_env: { "TASK_SHOW_JSON" => SHOW_JSON })
      assert_equal 1, code
      close = lines.find { |l| l[0] == "GATE" && l[1] == "close" }
      refute_nil close, "a red lane closes the G1 attempt: #{lines.inspect}"
      assert_includes close, "--failed"
    end
  end

  def test_print_mode_emits_no_gate_or_task_writes
    with_repo do |dir, _|
      out, code, lines = run_check(dir, args: ["task-x", "--print"], extra_env: { "TASK_SHOW_JSON" => SHOW_JSON })
      assert_equal 0, code, out
      assert_empty(lines.select { |l| %w[GATE TASK].include?(l[0]) },
                   "--print is a dry run — no durable-record writes: #{lines.inspect}")
      assert_match(/\[fast-cert@/, out, "the evidence line still prints")
    end
  end

  def test_cert_checkpoints_bound_the_run_in_non_print_mode
    with_repo do |dir, _|
      _, code, lines = run_check(dir, args: ["task-x"], extra_env: { "TASK_SHOW_JSON" => SHOW_JSON })
      assert_equal 0, code
      checkpoints = lines.select { |l| l[0] == "TASK" && l[1] == "checkpoint" }
      assert_equal [%w[started], %w[completed]],
                   checkpoints.map { |l| [l[l.index("--status") + 1]] },
                   "a cert checkpoint opens and closes the Local Certification window"
    end
  end

  def test_unreadable_task_checks_aborts_without_writing
    with_repo do |dir, _|
      # TASK stub fails on `show` → the runner must NOT blind-write --checks.
      out, code, lines = run_check(dir, args: ["task-x"],
                                        extra_env: { "TASK_SHOW_JSON" => "", "FAIL_TOKEN" => "show" })
      assert_equal 1, code, out
      refute(lines.any? { |l| l[0] == "TASK" && l[1] == "update" },
             "a blind --checks write would wipe tier tags — abort instead")
    end
  end

  # --- [integration] task-root guard: the cert must root at the TASK's tree ---------
  # Regression for the 2026-07-12 fail-GREEN: run from the hub primary (on main),
  # the cert rooted at the cwd's git toplevel and green-certified MAIN's tree for
  # an unrelated task. With a task slug and an IMPLICIT root (cwd, no
  # FAST_CHECK_ROOT), the cert must verify the root IS the task's tree —
  # its checked-out branch is the task's branch, or it is the task's
  # .worktrees/<worktree_slug> dir — and REFUSE otherwise (bin/lib/cert_root_guard.rb).

  GUARD_JSON = JSON.generate(
    "metadata" => { "devops" => {
      "branch" => "feat/task-x", "worktree_slug" => "task-x", "checks_run" => []
    } }
  )

  # --- [integration] desk guard: a desk that does not own its test DB may not certify ---
  # Right root, but is it a WHOLE desk? A desk whose test env resolves to the SHARED base
  # <app>_test certifies against the database the primary checkout and the release gate
  # workspaces are using — silently. bin/agent-worktree's bringup is atomic now and cannot
  # leave such a desk behind; this is the second lock, because desks half-built by the OLD
  # tool are still on disk and .env.test.local can be deleted by hand. bin/lib/desk_guard.rb.
  #
  # These drive the guard END TO END, through the shelled runner and a real `bin/rails`
  # boot (the fixture's shim — see write_repo_shape): DESK_DB_STUB is what the booted app
  # answers, and the verdict must follow THAT, never a declared string.

  def test_a_desk_with_no_isolated_test_db_is_refused_before_any_lane_runs
    with_repo(subpath: ".worktrees/half-built") do |dir, _|
      # The shim defaults to the SHARED name: bringup never gave this desk a DB of its own.
      out, code, lines = run_check(dir, implicit_root: true,
                                   extra_env: { "TEST_DATABASE_URL" => nil })

      assert_equal 1, code, "a desk with no isolated test DB must refuse, not certify: #{out}"
      assert_match(/no isolated test DB/, out)
      assert_match(/SHARED base test database/, out, "the refusal says WHY it matters")
      assert_match(/ENV issue/, out, "and names it as an env issue, not a regression in the diff")
      assert_empty lane_calls(lines, "TEST"), "the refusal fires BEFORE any lane runs"
      refute_match(/\[fast-cert@/, out, "nothing certified against a shared database")
    end
  end

  # THE BLOCKER-A VECTOR, end to end. The desk PINS an isolated test DB and the app IGNORES
  # the pin (turf-monster, whose database.yml had no `url:` key) — so it resolves to the
  # SHARED database anyway. The presence-checking guard certified this. It must refuse, and
  # it must say the pin is inert rather than send the operator back to bringup, which would
  # faithfully rewrite the very same inert pin.
  def test_a_desk_whose_pin_is_ignored_by_the_app_is_refused
    with_repo(subpath: ".worktrees/inert-pin") do |dir, write|
      write.call(".env.test.local", "TEST_DATABASE_URL=postgresql://localhost/studio_test_inert_pin\n")
      out, code, lines = run_check(dir, implicit_root: true,
                                   extra_env: { "TEST_DATABASE_URL" => nil }) # shim still answers SHARED

      assert_equal 1, code, "a pin the app ignores is not isolation: #{out}"
      assert_match(/SHARED test database/, out)
      assert_match(/IGNORES it/, out, "the refusal must name the app's config, not the desk")
      assert_empty lane_calls(lines, "TEST"), "the refusal fires BEFORE any lane runs"
    end
  end

  def test_a_desk_that_resolves_to_its_own_test_db_certifies_normally
    # The control: same desk layout, and the booted app really does land on its own DB. The
    # guard must not refuse a properly-provisioned worktree — that is where every cert
    # legitimately runs.
    with_repo(subpath: ".worktrees/whole-desk") do |dir, write|
      write.call(".env.test.local", "TEST_DATABASE_URL=postgresql://localhost/studio_test_whole_desk\n")
      out, code, lines = run_check(dir, implicit_root: true,
                                   extra_env: { "TEST_DATABASE_URL" => nil,
                                                "DESK_DB_STUB" => "studio_test_whole_desk" })

      assert_equal 0, code, out
      refute_empty lane_calls(lines, "TEST"), "the lanes must run in a whole desk"
    end
  end

  # A SQLite desk (rolio) has NO TEST_DATABASE_URL by design — its test DB is a FILE inside
  # the desk, private by construction. Demanding the pin refused a perfectly isolated tree,
  # which is how `new rolio <task>` came to create nothing at all.
  def test_a_sqlite_desk_certifies_with_no_pin_at_all
    with_repo(subpath: ".worktrees/rolio-desk") do |dir, _|
      out, code, lines = run_check(dir, implicit_root: true,
                                   extra_env: { "TEST_DATABASE_URL" => nil,
                                                "DESK_DB_STUB" => "storage/test.sqlite3" })

      assert_equal 0, code, "a SQLite desk's test DB is a file inside it — allow: #{out}"
      refute_empty lane_calls(lines, "TEST")
    end
  end

  def test_wrong_root_cert_is_refused_before_any_lane_runs
    with_repo do |dir, _|
      # cwd = a tree on its default branch (main/master) — NOT task-x's tree.
      out, code, lines = run_check(dir, args: ["task-x"], implicit_root: true,
                                   extra_env: { "TASK_SHOW_JSON" => GUARD_JSON })
      assert_equal 1, code, "a wrong-root cert must refuse, not green-certify: #{out}"
      assert_match(/not task-x's tree/, out, "the refusal names the task")
      assert_match(%r{feat/task-x}, out, "the refusal names the expected branch")
      refute_match(/\[fast-cert@/, out, "no evidence for a tree the task never touched")
      assert_empty lane_calls(lines, "TEST"), "refusal fires BEFORE any lane runs"
      refute(lines.any? { |l| l[0] == "GATE" }, "no G1 attempt opens for a refused run: #{lines.inspect}")
      refute(lines.any? { |l| l[0] == "TASK" && l[1] == "update" }, "nothing recorded for a refused run")
    end
  end

  def test_task_branch_checkout_certifies_without_a_root_override
    with_repo do |dir, _|
      assert system("git", "-C", dir, "checkout", "-qb", "feat/task-x", out: File::NULL, err: File::NULL)
      # COMMIT the branch diff first — the dirty-tree guard below now enforces what
      # was previously only a house rule, so the cert is the LAST build step. Diffing
      # from HEAD~1 keeps widget.rb in the mapped lane now that it is committed.
      commit_all(dir)
      out, code, lines = run_check(dir, args: ["task-x"], implicit_root: true,
                                   extra_env: { "TASK_SHOW_JSON" => GUARD_JSON,
                                                "FAST_CHECK_DIFF_BASE" => "HEAD~1" })
      assert_equal 0, code, "the task's own tree certifies from cwd with no override: #{out}"
      assert_match(/\[fast-cert@/, out)
      assert(lines.any? { |l| l[0] == "TASK" && l[1] == "update" }, "evidence recorded: #{lines.inspect}")
      assert_includes lane_calls(lines, "TEST").flatten, "test/models/widget_test.rb",
                      "the mapped lane still selects off the diff once it is committed"
    end
  end

  # --- [integration] dirty-tree guard: certify only a fully-committed HEAD ----------
  # The cert fingerprint is a git TREE hash of the WORKING tree, so a cert taken with
  # edits uncommitted stamps GREEN evidence for code the PR never receives — live on
  # 2026-07-14, when a worktree's 146 lines of finished, tested work were certified
  # and then never reached PR #537. The refusal must land BEFORE any lane runs or any
  # gate/checkpoint/evidence write, exactly like the root guard above
  # (bin/lib/cert_tree_guard.rb).

  def test_dirty_tree_cert_is_refused_before_any_lane_runs
    with_repo do |dir, _|
      assert system("git", "-C", dir, "checkout", "-qb", "feat/task-x", out: File::NULL, err: File::NULL)
      # The RIGHT tree (task-x's branch) — but widget.rb is still uncommitted.
      out, code, lines = run_check(dir, args: ["task-x"], implicit_root: true,
                                   extra_env: { "TASK_SHOW_JSON" => GUARD_JSON })

      assert_equal 1, code, "an uncommitted tree must refuse, not green-certify: #{out}"
      assert_match(/DIRTY/, out)
      assert_match(%r{app/models/widget\.rb}, out, "the refusal NAMES the uncommitted file")
      assert_match(/commit/i, out, "the refusal states the fix")
      refute_match(/\[fast-cert@/, out, "no evidence for a tree that is not on the PR")
      assert_empty lane_calls(lines, "TEST"), "refusal fires BEFORE any lane runs"
      refute(lines.any? { |l| l[0] == "GATE" }, "no G1 attempt opens for a refused run: #{lines.inspect}")
      refute(lines.any? { |l| l[0] == "TASK" && l[1] == "update" }, "nothing recorded for a refused run")
    end
  end

  def test_stale_mtime_tree_still_certifies
    # THE FALSE POSITIVE the guard must not become. A tracked file rewritten with
    # IDENTICAL content has a fresh mtime, leaving git's stat cache stale — which the
    # cheap dirty reads (git diff-index) call MODIFIED. On the CERT path a false
    # refusal blocks every handoff, so the guard refreshes the index before reading
    # it. Unit-level proof, including the index-refresh mechanism itself, lives in
    # test/lib/cert_tree_guard_test.rb.
    with_repo do |dir, _|
      assert system("git", "-C", dir, "checkout", "-qb", "feat/task-x", out: File::NULL, err: File::NULL)
      commit_all(dir)

      tracked = File.join(dir, "app/models/widget.rb")
      body = File.read(tracked)
      File.write(tracked, body)                                       # byte-identical rewrite
      FileUtils.touch(tracked, mtime: Time.now + (10 * 365 * 24 * 3600))
      refute system("git", "-C", dir, "diff-index", "--quiet", "HEAD", out: File::NULL, err: File::NULL),
             "fixture check: the index must actually BE stat-stale, else this proves nothing"

      out, code, lines = run_check(dir, args: ["task-x"], implicit_root: true,
                                   extra_env: { "TASK_SHOW_JSON" => GUARD_JSON,
                                                "FAST_CHECK_DIFF_BASE" => "HEAD~1" })

      assert_equal 0, code, "a stat-stale index is a CLEAN tree — it must still certify: #{out}"
      refute_match(/DIRTY/, out, "a file nobody edited must never be reported as uncommitted work")
      assert_match(/\[fast-cert@/, out)
      assert(lines.any? { |l| l[0] == "TASK" && l[1] == "update" }, "evidence recorded: #{lines.inspect}")
    end
  end

  def test_explicit_root_override_bypasses_the_dirty_tree_guard
    # Same contract as the root guard: an EXPLICIT FAST_CHECK_ROOT is the deliberate
    # CI/test seam, so it bypasses. (run_check's default path sets it — that is why
    # every other test in this file certifies against the fixture's uncommitted diff.)
    with_repo do |dir, _|
      out, code, = run_check(dir, args: ["task-x"], extra_env: { "TASK_SHOW_JSON" => GUARD_JSON })
      assert_equal 0, code, "an explicitly-declared root still certifies: #{out}"
      refute_match(/DIRTY/, out)
    end
  end

  # Commit everything in `dir` — the fixture's uncommitted branch diff — so the cert
  # runs against a fully-committed HEAD, which the dirty-tree guard now requires.
  def commit_all(dir)
    assert system("git", "-C", dir, "add", "-A", out: File::NULL, err: File::NULL)
    assert system("git", "-C", dir, "commit", "-qm", "widget", out: File::NULL, err: File::NULL)
  end
end
