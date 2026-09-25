# frozen_string_literal: true

# Harness tests for bin/fast-check — the OPTIONAL local pre-flight (diff-mapped
# tests + core spine + rubocop on changed files). Since DevOps v3 phase 2b
# (/tasks/retire-local-cert-evidence) it records NOTHING on the task: no receipt,
# no gate attempt, no checkpoint. The PR's settled green CI is the verdict; this
# script buys earliness and says so.
#
# The script is shelled with its lanes stubbed via FAST_CHECK_* env vars against
# throwaway git repos, so the ORCHESTRATION is exercised without a real Rails run;
# the board CLI is stubbed via FAST_CHECK_TASK_BIN so the one read it still makes
# (the tree check) can be driven and every write it must NOT make can be asserted
# absent. Selection logic itself is unit-tested in test/lib/fast_cert_test.rb.
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

class FastCheckTest < Minitest::Test
  BIN = File.expand_path("../../bin/fast-check", __dir__)

  # THE CHILD HAS NO DATABASE. The desk guard boots the app it finds; a tmpdir fixture
  # must not inherit this process's TEST_DATABASE_URL and go probing the desk's DB.
  NO_AMBIENT_DB = { "TEST_DATABASE_URL" => nil, "CERT_GUARD_PSQL" => "/nonexistent/psql" }.freeze

  def child_env(overrides = {})
    SessionEnv.neutralized(NO_AMBIENT_DB.merge(overrides))
  end

  # --- fixtures --------------------------------------------------------------------

  # A temp git repo shaped like an app: a changed model + its convention test, a
  # spine test + spine config, and one committed baseline. Yields the dir and a
  # writer. `subpath:` puts the repo under e.g. ".worktrees/<slug>", which is what
  # makes it read as an agent DESK (DeskGuard).
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
      write_repo_shape(dir, subpath) if subpath
      write.call(".gitignore", "stub.log*\n*-stub\n")
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

  # Make a desk fixture REPO-SHAPED: the desk guard boots the app and reads back the
  # database it connects to, so a desk needs the repo's config/database.yml (one level
  # up from <repo>/.worktrees/<slug>) and a `bin/rails` to boot. The shim answers with
  # DESK_DB_STUB, defaulting to the SHARED name — the hazard.
  def write_repo_shape(dir, subpath)
    repo_root = File.expand_path("../..", dir)
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

  # A stub CLI: appends "<MARKER>\t<argv...>" to STUB_LOG; exits 1 when FAIL_TOKEN is
  # set and appears in its argv. The TASK stub serves `show` from TASK_SHOW_JSON.
  def write_stub(dir, name, marker)
    stub = File.join(dir, name)
    File.write(stub, <<~RUBY)
      #!#{RbConfig.ruby}
      log = ENV.fetch("STUB_LOG")
      File.open(log, "a") { |f| f.puts(["#{marker}", *ARGV].join("\\t")) }
      if ARGV.first == "show"
        json = ENV["TASK_SHOW_JSON"].to_s
        puts json unless json.empty?
      end
      token = ENV["FAIL_TOKEN"].to_s
      exit(!token.empty? && ARGV.join(" ").include?(token) ? 1 : 0)
    RUBY
    FileUtils.chmod("+x", stub)
    stub
  end

  # A repo fixture that IDENTIFIES as a given slug (TaskTree.repo_of_checkout reads
  # the origin remote), so a registry-driven test can be written at all.
  def with_repo_named(slug, release_check: nil)
    with_repo do |dir|
      assert system("git -C #{dir} remote add origin " \
                    "https://github.com/McRitchie-Studio/#{slug}.git >/dev/null 2>&1"),
             "could not name the fixture repo #{slug}"
      if release_check
        FileUtils.mkdir_p(File.join(dir, "bin"))
        File.write(File.join(dir, "bin/release-check"), release_check)
        File.chmod(0o755, File.join(dir, "bin/release-check"))
      end
      yield dir
    end
  end

  GEM_GATE_OK = "#!/bin/sh\nexit 0\n"
  GEM_GATE_RED = "#!/bin/sh\nexit 1\n"

  GUARD_JSON = JSON.generate(
    "metadata" => { "devops" => {
      "branch" => "feat/task-x", "worktree_slug" => "task-x", "checks_run" => []
    } }
  )

  # Run bin/fast-check against `dir` with every seam stubbed. Returns [output,
  # exitcode, log_lines]; the narration is stderr, so it is merged by default.
  # implicit_root: true drops FAST_CHECK_ROOT and runs WITH `dir` as the cwd, so the
  # root resolves from the cwd git toplevel and the tree check is exercised.
  def run_check(dir, args: [], fail_token: "", extra_env: {}, implicit_root: false, bin: BIN)
    log = File.join(dir, "stub.log")
    lane = write_stub(dir, "lane-stub", "LANE")
    task = write_stub(dir, "task-stub", "TASK")
    env = child_env({
      "FAST_CHECK_ROOT" => dir,
      "FAST_CHECK_DIFF_BASE" => "HEAD",
      "FAST_CHECK_SPINE" => File.join(dir, "spine.yml"),
      "FAST_CHECK_TEST_PREPARE_CMD" => "true",
      "FAST_CHECK_TEST_CMD" => "#{lane.shellescape} TEST",
      "FAST_CHECK_RUBOCOP_CMD" => "#{lane.shellescape} RUBOCOP",
      "FAST_CHECK_TASK_BIN" => task,
      "STUB_LOG" => log,
      "FAIL_TOKEN" => fail_token
    }.merge(extra_env))
    cmd = "#{bin.shellescape} #{args.map(&:shellescape).join(' ')}"
    out =
      if implicit_root
        env.delete("FAST_CHECK_ROOT")
        IO.popen(env, "#{cmd} 2>&1", chdir: dir, &:read)
      else
        IO.popen(env, "#{cmd} 2>&1", &:read)
      end
    code = $?.exitstatus
    lines = File.exist?(log) ? File.readlines(log, chomp: true).map { |l| l.split("\t") } : []
    [out, code, lines]
  end

  def lane_calls(lines, first_arg)
    lines.select { |l| l[0] == "LANE" && l[1] == first_arg }.map { |l| l[2..] }
  end

  def board_writes(lines)
    lines.select { |l| l[0] == "TASK" && l[1] != "show" }
  end

  def commit_all(dir)
    assert system("git", "-C", dir, "add", "-A", out: File::NULL, err: File::NULL)
    assert system("git", "-C", dir, "commit", "-qm", "widget", out: File::NULL, err: File::NULL)
  end

  # --- [integration] the pre-flight writes NOTHING ---------------------------------

  def test_a_green_run_records_nothing_on_the_task
    with_repo do |dir, _|
      assert system("git", "-C", dir, "checkout", "-qb", "feat/task-x", out: File::NULL, err: File::NULL)
      commit_all(dir)
      out, code, lines = run_check(dir, args: ["task-x"], implicit_root: true,
                                   extra_env: { "TASK_SHOW_JSON" => GUARD_JSON, "FAST_CHECK_DIFF_BASE" => "HEAD~1" })

      assert_equal 0, code, out
      assert_match(/pre-flight green: 1 mapped \+ 1 spine test path\(s\)/, out)
      assert_match(/Nothing is recorded on the task/, out, "the run says out loud what it did not do")
      refute_match(/\[fast-cert@|\[cert-deferred@|\[full-suite@/, out, "no receipt of any lane")
      assert_empty board_writes(lines), "no bin/task update, no checkpoint, no gate: #{lines.inspect}"
      assert_equal [%w[show task-x --json]], lines.select { |l| l[0] == "TASK" }.map { |l| l[1..] },
                   "the ONLY board read is the tree check"
    end
  end

  def test_a_dirty_tree_runs_because_nothing_is_stamped
    with_repo do |dir, _|
      assert system("git", "-C", dir, "checkout", "-qb", "feat/task-x", out: File::NULL, err: File::NULL)
      # widget.rb is still uncommitted — the retired dirty-tree guard refused this.
      out, code, lines = run_check(dir, args: ["task-x"], implicit_root: true,
                                   extra_env: { "TASK_SHOW_JSON" => GUARD_JSON })

      assert_equal 0, code, "a pre-flight stamps no tree, so an uncommitted tree is fine to run: #{out}"
      refute_match(/DIRTY/, out)
      assert_includes lane_calls(lines, "TEST").flatten, "test/models/widget_test.rb"
    end
  end

  def test_the_print_flag_is_gone_with_the_receipt_it_suppressed
    with_repo do |dir, _|
      out, code, = run_check(dir, args: ["--print"])

      refute_equal 0, code, "--print used to mean 'do not record'; there is nothing to not record"
      assert_match(/invalid option: --print/, out)
    end
  end

  # --- [unit] lanes + selection wiring --------------------------------------------

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
      assert_equal ["app/models/widget.rb"], lint[0], "rubocop runs on the CHANGED file only"
    end
  end

  def test_mapped_tests_already_covered_by_the_spine_run_once
    with_repo do |dir, write|
      write.call("app/models/spine_core.rb", "class SpineCore; end\n")
      _, code, lines = run_check(dir)
      assert_equal 0, code
      tests = lane_calls(lines, "TEST")
      assert_equal ["test/models/widget_test.rb"], tests[0], "spine-covered mapped test dropped from the mapped lane"
      assert_equal ["test/models/spine_core_test.rb"], tests[1]
    end
  end

  def test_doc_only_diff_skips_test_and_rubocop_lanes_but_still_runs_the_spine
    with_repo do |dir, write|
      write.call("docs/notes.md", "notes\n")
      out, code, lines = run_check(dir, extra_env: { "FAST_CHECK_CHANGED_FILES" => "docs/notes.md" },
                                        fail_token: "RUBOCOP")
      assert_equal 0, code, out
      assert_empty lane_calls(lines, "RUBOCOP"), "no lintable files → rubocop lane skipped"
      assert_equal [["test/models/spine_core_test.rb"]], lane_calls(lines, "TEST"), "the spine still runs"
    end
  end

  def test_list_mode_prints_the_selection_without_running_anything
    with_repo do |dir, _|
      out, code, lines = run_check(dir, args: ["--list"])
      assert_equal 0, code, out
      assert_match(%r{mapped\s+test/models/widget_test\.rb}, out)
      assert_match(%r{spine\s+test/models/spine_core_test\.rb}, out)
      assert_match(%r{lint\s+app/models/widget\.rb}, out)
      assert_empty lines, "--list must not run lanes or touch the board"
    end
  end

  # --- red, hung and unlaunchable lanes -------------------------------------------

  def test_red_test_lane_exits_nonzero
    with_repo do |dir, _|
      out, code, = run_check(dir, fail_token: "widget_test")
      assert_equal 1, code, out
      assert_match(/lane\(s\) RED: mapped-tests/, out)
      refute_match(/pre-flight green/, out)
    end
  end

  def test_red_rubocop_lane_exits_nonzero
    with_repo do |dir, _|
      out, code, = run_check(dir, fail_token: "RUBOCOP")
      assert_equal 1, code, out
      assert_match(/lane\(s\) RED: rubocop-changed/, out)
    end
  end

  def test_a_timed_out_runner_is_named_as_hung_never_as_a_red_suite
    with_repo do |dir, _|
      slow_runner = "#{RbConfig.ruby.shellescape} -e #{"sleep 30".shellescape} --"
      out, code, = run_check(dir, extra_env: { "FAST_CHECK_TEST_CMD" => slow_runner,
                                              "FAST_CHECK_LANE_TIMEOUT" => "1" })

      assert_equal 1, code, out
      assert_match(/lane HUNG/, out)
      assert_match(/NOT a red suite/, out)
      assert_match(/FAST_CHECK_LANE_TIMEOUT/, out)
      refute_match(/lane\(s\) RED/, out, "a runner that produced no verdict must never be reported as red tests")
    end
  end

  def test_test_prepare_failure_aborts_before_any_lane
    with_repo do |dir, _|
      out, code, lines = run_check(dir, extra_env: { "FAST_CHECK_TEST_PREPARE_CMD" => "false" })
      assert_equal 1, code, out
      assert_match(/test-env prepare failed/, out)
      assert_empty lane_calls(lines, "TEST"), "no test lane runs on a failed prepare"
    end
  end

  def test_an_absent_prepare_runner_is_could_not_run_not_an_env_gap
    with_repo do |dir, _|
      out, code, = run_check(dir, extra_env: { "FAST_CHECK_TEST_PREPARE_CMD" => "/nonexistent/rails db:test:prepare" })

      assert_equal 1, code, out
      assert_match(/COULD NOT RUN/, out)
      refute_match(/USUALLY an ENV gap/, out)
      assert_match(/release_check:/, out, "the remedy names the registry key that declares a non-Rails lane")
      assert_match(%r{config/release_repos\.yml}, out)
    end
  end

  # --- the virgin-tree bundled-asset regression -----------------------------------
  # fast-check's test lanes pass explicit paths, and Rails skips its own test:prepare
  # whenever an argument looks like a path — so the prepare lane must invoke the hook
  # that builds the gitignored CSS itself, or every view test in a fresh desk errors.
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

  def test_prepare_lane_builds_bundled_assets_before_the_path_arg_test_lanes
    with_repo do |dir, _|
      write_fake_rails(dir)
      out, code, lines = run_check(dir, extra_env: { "FAST_CHECK_TEST_PREPARE_CMD" => nil,
                                                     "FAST_CHECK_TEST_CMD" => nil,
                                                     "FAST_CHECK_RUBOCOP_CMD" => "true" })
      rails = lines.select { |l| l[0] == "RAILS" }.map { |l| l[1..] }

      assert_equal ["db:test:prepare", "test:prepare"], rails[0]
      assert_path_exists File.join(dir, "app/assets/builds/tailwind.css")
      assert_equal ["test", "test/models/widget_test.rb"], rails[1]
      assert_equal ["test", "test/models/spine_core_test.rb"], rails[2]
      assert_equal 0, code, "a virgin tree must run green, not red on a missing asset:\n#{out}"
    end
  end

  # --- registry-gated repos ---------------------------------------------------------

  def test_a_gem_repo_runs_its_registry_gate_and_no_rails_lane
    with_repo_named("studio-engine", release_check: GEM_GATE_OK) do |dir|
      log = File.join(dir, "stub.log")
      out, code = run_check(dir, extra_env: {
        "FAST_CHECK_TEST_CMD" => nil,
        "FAST_CHECK_TEST_PREPARE_CMD" => "sh -c 'echo PREPARE >> #{log.shellescape}'"
      })

      assert_equal 0, code, "an unaided gem pre-flight must complete:\n#{out}"
      refute_match(/PREPARE/, File.exist?(log) ? File.read(log) : "",
                   "a gem has no test database — the prepare lane must not APPLY")
      assert_match(/whole registry gate/, out, "the summary names what was actually executed")
      refute_match(/Errno::ENOENT/, out)
    end
  end

  def test_a_gem_repo_invokes_no_rubocop_lane_at_all
    with_repo_named("studio-engine", release_check: GEM_GATE_OK) do |dir|
      _, code, lines = run_check(dir, fail_token: "RUBOCOP", extra_env: { "FAST_CHECK_TEST_CMD" => nil })

      assert_equal 0, code
      assert_empty lane_calls(lines, "RUBOCOP")
    end
  end

  def test_a_gem_whose_gate_fails_is_red
    with_repo_named("studio-engine", release_check: GEM_GATE_RED) do |dir|
      out, code, = run_check(dir, extra_env: { "FAST_CHECK_TEST_CMD" => nil })

      assert_equal 1, code, out
      assert_match(/lane\(s\) RED: registry-gate/, out)
    end
  end

  def test_a_gem_missing_its_declared_gate_is_could_not_run
    with_repo_named("studio-engine") do |dir|
      out, code, = run_check(dir, extra_env: { "FAST_CHECK_TEST_CMD" => nil })

      assert_equal 1, code, out
      assert_match(/COULD NOT RUN: registry-gate/, out)
      refute_match(/lane\(s\) RED/, out, "a missing command is not a failing test")
    end
  end

  def test_a_registry_gated_app_repo_runs_its_declared_gate_and_no_rails_lane
    with_repo_named("turf-vault", release_check: GEM_GATE_OK) do |dir|
      log = File.join(dir, "stub.log")
      out, code, lines = run_check(dir, fail_token: "RUBOCOP", extra_env: {
        "FAST_CHECK_TEST_CMD" => nil,
        "FAST_CHECK_TEST_PREPARE_CMD" => "sh -c 'echo PREPARE >> #{log.shellescape}'"
      })

      assert_equal 0, code, out
      refute_match(/PREPARE/, File.exist?(log) ? File.read(log) : "")
      assert_empty lane_calls(lines, "RUBOCOP")
      assert_match(/whole registry gate/, out)
    end
  end

  def test_an_app_that_declares_no_gate_keeps_the_rails_path
    with_repo_named("turf-monster") do |dir|
      out, code, lines = run_check(dir)

      assert_equal 0, code, out
      assert_equal 2, lane_calls(lines, "TEST").size
      assert_match(/1 mapped/, out, "an app still reports its diff-mapped selection")
    end
  end

  # --- the mapped cap ---------------------------------------------------------------

  # A twin-less model whose grep matches many test files — the real shape of a cap trip.
  def with_wide_mapping_repo
    with_repo do |dir, write|
      (1..20).each { |i| write.call("test/lib/wide_#{i}_test.rb", "Gizmo.reset\n") }
      commit_all(dir)
      write.call("app/models/gizmo.rb", "class Gizmo; end\n")
      yield dir, write
    end
  end

  def test_a_wide_mapping_skips_the_mapped_lane_and_still_runs_the_spine
    with_wide_mapping_repo do |dir, _|
      out, code, lines = run_check(dir)

      assert_equal 0, code, "the cap is not a failure — it is a narrower pre-flight"
      assert_equal [["test/models/spine_core_test.rb"]], lane_calls(lines, "TEST")
      assert_match(/MAPPED LANE CAPPED/, out)
      assert_match(/exceeds the cap of 15/, out)
      assert_match(%r{widest mapping: app/models/gizmo\.rb}, out, "the culprit is named")
      assert_match(/FAST_CHECK_MAPPED_CAP/, out, "the deliberate override is discoverable")
      assert_match(/CI runs the full mapped set on the PR/, out, "the net is named, not a local full suite")
      refute_match(/full-suite-check/, out, "the retired local full suite is never offered")
      assert_match(/pre-flight green: 0 mapped \(CAPPED: 20 mapped path\(s\) over the cap of 15; spine only\)/, out)
    end
  end

  def test_raising_the_cap_runs_the_mapped_lane
    with_wide_mapping_repo do |dir, _|
      _, code, lines = run_check(dir, extra_env: { "FAST_CHECK_MAPPED_CAP" => "500" })

      assert_equal 0, code
      assert_equal 2, lane_calls(lines, "TEST").size
    end
  end

  def test_a_wide_mapping_that_the_spine_already_covers_is_not_capped
    with_repo do |dir, write|
      write.call("app/models/base_gizmo.rb", "class BaseGizmo; end\n")
      wide = (1..20).map { |i| "test/lib/wide_#{i}_test.rb" }
      wide.each { |rel| write.call(rel, "Gizmo.reset\n") }
      spined = wide.first(18)
      write.call("spine.yml", "spine:\n#{spined.map { |r| "  - #{r}" }.join("\n")}\n")
      commit_all(dir)
      write.call("app/models/gizmo.rb", "class Gizmo; end\n")

      out, code, lines = run_check(dir)

      assert_equal 0, code
      refute_match(/MAPPED LANE CAPPED/, out, "the cap reads the post-spine set (2), not the raw mapping (20)")
      tests = lane_calls(lines, "TEST")
      assert_equal 2, tests.size
      assert_equal wide.last(2).sort, tests[0].sort
    end
  end

  def test_a_narrow_diff_is_unaffected_by_the_cap
    with_repo do |dir, _|
      out, code, lines = run_check(dir)

      assert_equal 0, code
      assert_equal 2, lane_calls(lines, "TEST").size
      refute_match(/MAPPED LANE CAPPED|NEAR THE CAP/, out)
    end
  end

  # --- the margin: the run BEFORE the cliff -----------------------------------------

  def with_at_cap_mapping_repo
    with_repo do |dir, write|
      (1..15).each { |i| write.call("test/lib/wide_#{i}_test.rb", "Gizmo.reset\n") }
      commit_all(dir)
      write.call("app/models/gizmo.rb", "class Gizmo; end\n")
      yield dir, write
    end
  end

  def with_at_cap_family_repo
    with_repo do |dir, write|
      write.call("bin/wide-tool", "#!/usr/bin/env ruby\n")
      write.call("test/lib/wide_tool_test.rb", "twin\n")
      14.times { |i| write.call("test/lib/wide_tool_aspect#{i}_test.rb", "sibling #{i}\n") }
      commit_all(dir)
      write.call("bin/wide-tool", "#!/usr/bin/env ruby\n# edit\n")
      yield dir, write
    end
  end

  def test_the_lane_warns_at_the_cap_and_still_runs_its_whole_mapped_set
    with_at_cap_mapping_repo do |dir, _|
      out, code, lines = run_check(dir)

      assert_equal 0, code, out
      assert_match(/MAPPED LANE NEAR THE CAP — 15 of 15, 0 path\(s\) of margin left/, out)
      assert_match(%r{widest mapping: app/models/gizmo\.rb → 15 test file\(s\)}, out)
      assert_match(/NO convention twin to fall back to.*runs ZERO tests/m, out)
      tests = lane_calls(lines, "TEST")
      assert_equal 15, tests[0].size, "the whole mapped set still runs — this is not a cap trip"
      refute_match(/MAPPED LANE CAPPED/, out)
    end
  end

  def test_the_near_cap_warning_names_the_twin_fallback_when_one_exists
    with_at_cap_family_repo do |dir, _|
      out, code, = run_check(dir)

      assert_equal 0, code, out
      assert_match(/falls back to the 1 convention twin\(s\) of this diff — a NARROWER pre-flight/, out)
      refute_match(/runs ZERO tests/, out)
    end
  end

  # --- the cap's TWIN FALLBACK -------------------------------------------------------

  def with_family_over_cap_repo
    with_repo do |dir, write|
      write.call("bin/wide-tool", "#!/usr/bin/env ruby\n")
      write.call("test/lib/wide_tool_test.rb", "twin\n")
      20.times { |i| write.call("test/lib/wide_tool_aspect#{i}_test.rb", "sibling #{i}\n") }
      commit_all(dir)
      write.call("bin/wide-tool", "#!/usr/bin/env ruby\n# edit\n")
      yield dir, write
    end
  end

  def test_a_capped_family_runs_its_convention_twin_instead_of_nothing
    with_family_over_cap_repo do |dir, _|
      out, code, lines = run_check(dir)

      assert_equal 0, code, out
      tests = lane_calls(lines, "TEST")
      assert_equal [["test/lib/wide_tool_test.rb"], ["test/models/spine_core_test.rb"]], tests
      assert_match(/falling back to the CONVENTION TWINS/, out)
      assert_match(/pre-flight green: 1 twin\(s\) \(CAPPED: 21 mapped path\(s\) over the cap of 15\)/, out)
    end
  end

  def with_spine_covered_twin_repo
    with_repo do |dir, write|
      (1..20).each { |i| write.call("test/lib/wide_#{i}_test.rb", "Gizmo.reset\n") }
      write.call("spine.yml", "spine:\n  - test/models/spine_core_test.rb\n  - test/models/widget_test.rb\n")
      commit_all(dir)
      write.call("app/models/widget.rb", "class Widget\n  def id\n    1\n  end\nend\n")
      write.call("app/models/gizmo.rb", "class Gizmo; end\n")
      yield dir, write
    end
  end

  def test_a_spine_covered_twin_is_not_reported_as_no_twin_at_all
    with_spine_covered_twin_repo do |dir, _|
      out, code, lines = run_check(dir)

      assert_equal 0, code, out
      assert_match(/MAPPED LANE CAPPED/, out)
      refute_match(/no changed file has an existing test twin/, out)
      assert_match(/ALREADY A SPINE ENTRY/, out)
      assert_equal [%w[test/models/spine_core_test.rb test/models/widget_test.rb]], lane_calls(lines, "TEST")
    end
  end

  def test_the_capped_preview_lists_each_twin_exactly_once
    with_family_over_cap_repo do |dir, _|
      out, code, = run_check(dir, args: ["--list"])

      assert_equal 0, code, out
      assert_equal ["twin    test/lib/wide_tool_test.rb"], out.lines.map(&:chomp).select { |l| l.start_with?("twin") }
    end
  end

  # --- nothing to run: a fact, not a refusal ---------------------------------------
  # The retired cert REFUSED or DEFERRED a run that would execute zero tests, because
  # it was about to stamp evidence. The pre-flight stamps nothing: it says no test lane
  # ran and exits 0. CI runs the whole suite on the PR either way.

  def satellite_spine(write)
    write.call("spine.yml", "spine:\n  - test/models/task_test.rb\n  - test/models/release_test.rb\n")
  end

  def test_a_docs_only_diff_on_a_satellite_checkout_runs_no_test_lane_and_says_so
    with_repo do |dir, write|
      satellite_spine(write)
      write.call("docs/notes.md", "notes\n")
      out, code, lines = run_check(dir, extra_env: { "FAST_CHECK_CHANGED_FILES" => "docs/notes.md" })

      assert_equal 0, code, "nothing to run is not a failure:\n#{out}"
      assert_match(/NO TEST LANE TO RUN — the diff maps to no test file, and this checkout resolves NONE of the 2 spine entries/, out)
      assert_match(/GitHub CI runs the full suite on the PR/, out)
      assert_match(/pre-flight ran no lane/, out)
      assert_empty lane_calls(lines, "TEST")
      refute_match(/DEFERR|REFUSING|full-suite-check/, out, "no deferral, no refusal, no local full suite")
    end
  end

  def test_a_capped_diff_with_no_twin_over_an_empty_spine_runs_no_test_lane
    with_wide_mapping_repo do |dir, write|
      write.call("spine.yml", "spine: []\n")

      out, code, lines = run_check(dir)

      assert_equal 0, code, out
      assert_match(/NO TEST LANE TO RUN — the mapped lane was CAPPED/, out)
      assert_match(/no spine is declared/, out)
      assert_empty lane_calls(lines, "TEST")
      assert_equal 1, lane_calls(lines, "RUBOCOP").size, "rubocop still lints the changed file"
    end
  end

  def test_a_red_lane_on_the_same_satellite_checkout_still_fails
    with_repo do |dir, write|
      satellite_spine(write)
      out, code, lines = run_check(dir, fail_token: "TEST")

      assert_equal 1, code, out
      assert_match(/lane\(s\) RED: mapped-tests/, out)
      assert_equal [["test/models/widget_test.rb"]], lane_calls(lines, "TEST")
    end
  end

  def test_a_mapped_lane_on_a_satellite_checkout_runs_normally
    with_repo do |dir, write|
      satellite_spine(write)
      out, code, lines = run_check(dir)

      assert_equal 0, code, out
      assert_equal [["test/models/widget_test.rb"]], lane_calls(lines, "TEST"), "one mapped run and NO spine run"
      assert_match(/pre-flight green: 1 mapped \+ 0 spine/, out)
    end
  end

  # --- desk guard: a desk that does not own its test DB may not run a lane ----------

  def test_a_desk_with_no_isolated_test_db_is_refused_before_any_lane_runs
    with_repo(subpath: ".worktrees/half-built") do |dir, _|
      out, code, lines = run_check(dir, implicit_root: true)

      assert_equal 1, code, out
      assert_match(/no isolated test DB/, out)
      assert_match(/SHARED base test database/, out)
      assert_empty lane_calls(lines, "TEST"), "the refusal fires BEFORE any lane runs"
    end
  end

  def test_a_desk_that_resolves_to_its_own_test_db_runs_normally
    with_repo(subpath: ".worktrees/whole-desk") do |dir, write|
      write.call(".env.test.local", "TEST_DATABASE_URL=postgresql://localhost/studio_test_whole_desk\n")
      out, code, lines = run_check(dir, implicit_root: true, extra_env: { "DESK_DB_STUB" => "studio_test_whole_desk" })

      assert_equal 0, code, out
      refute_empty lane_calls(lines, "TEST")
    end
  end

  def test_a_sqlite_desk_runs_with_no_pin_at_all
    with_repo(subpath: ".worktrees/rolio-desk") do |dir, _|
      out, code, lines = run_check(dir, implicit_root: true, extra_env: { "DESK_DB_STUB" => "storage/test.sqlite3" })

      assert_equal 0, code, out
      refute_empty lane_calls(lines, "TEST")
    end
  end

  # --- the tree check: the pre-flight must root at the TASK's tree ------------------

  def test_wrong_root_is_refused_before_any_lane_runs
    with_repo do |dir, _|
      out, code, lines = run_check(dir, args: ["task-x"], implicit_root: true,
                                   extra_env: { "TASK_SHOW_JSON" => GUARD_JSON })
      assert_equal 1, code, "a wrong-root pre-flight tells the builder nothing about their diff: #{out}"
      assert_match(/not task-x's tree/, out)
      assert_match(%r{feat/task-x}, out)
      assert_match(/refusing to run against it/, out)
      assert_empty lane_calls(lines, "TEST"), "refusal fires BEFORE any lane runs"
    end
  end

  def test_a_sibling_tree_desk_runs_on_its_physical_vouch
    with_repo(subpath: "studio-engine.worktrees/task-x") do |dir, _|
      commit_all(dir)
      out, code, lines = run_check(dir, args: ["task-x"], implicit_root: true,
                                   extra_env: { "TASK_SHOW_JSON" => GUARD_JSON, "FAST_CHECK_DIFF_BASE" => "HEAD~1" })

      assert_equal 0, code, out
      refute_match(/not task-x's tree/, out)
      refute_empty lane_calls(lines, "TEST")
    end
  end

  def test_a_sibling_tree_directory_that_is_not_the_tasks_desk_still_refuses
    with_repo(subpath: "studio-engine.worktrees/some-other-task") do |dir, _|
      out, code, lines = run_check(dir, args: ["task-x"], implicit_root: true,
                                   extra_env: { "TASK_SHOW_JSON" => GUARD_JSON })

      assert_equal 1, code, out
      assert_match(/not task-x's tree/, out)
      assert_empty lane_calls(lines, "TEST")
    end
  end

  def test_explicit_root_override_bypasses_the_tree_check
    with_repo do |dir, _|
      out, code, lines = run_check(dir, args: ["task-x"], extra_env: { "TASK_SHOW_JSON" => GUARD_JSON })
      assert_equal 0, code, out
      refute_match(/not task-x's tree/, out)
      assert_empty lines.select { |l| l[0] == "TASK" }, "an explicit root reads nothing from the board"
    end
  end
end
