# frozen_string_literal: true

# Integration test for bin/control-check — the EXECUTED half of the `test-only`
# shape's control. Drives the real script against a throwaway git repo with a
# stubbed test command and a stubbed board CLI. Run directly:
#   ruby -Itest test/lib/control_check_test.rb
#
# HOW THESE TESTS PROVE THE HARNESS ACTUALLY SWAPPED
#
# The stub test command is `grep -q NEWMARKER <paths>`, and the fixtures are built
# so the marker exists ONLY in the post-change content. So:
#   * a harness that correctly restores the pre-change file  → grep fails → NECESSARY
#   * a harness that silently failed to swap (the `sed -i ''` no-op class of bug)
#     would run the NEW file twice → grep passes → NO-SIGNAL
# Asserting NECESSARY is therefore an assertion that the swap BIT, not merely that
# the script exited 0. A harness test that cannot fail when the harness stops
# working is the thing being guarded against here.

require "minitest/autorun"
require "json"
require "tmpdir"
require "fileutils"
require_relative "../support/session_env"

class ControlCheckTest < Minitest::Test
  BIN = File.expand_path("../../bin/control-check", __dir__)

  # A throwaway repo with a BASE commit and a HEAD commit. `base` / `head` are
  # {path => content} maps; a path present in base and absent in head is deleted.
  def with_repo(base:, head:)
    Dir.mktmpdir do |dir|
      git = ->(args) { assert(system("git -C #{dir} #{args} >/dev/null 2>&1"), "git #{args}") }
      write = lambda do |rel, body|
        full = File.join(dir, rel)
        FileUtils.mkdir_p(File.dirname(full))
        File.write(full, body)
      end
      git.call("init -q")
      git.call("config user.email tester@example.com")
      git.call("config user.name tester")
      base.each { |rel, body| write.call(rel, body) }
      git.call("add -A")
      # --allow-empty: the added-only fixture has NO base files at all.
      git.call("commit -q --allow-empty -m base")
      git.call("branch base-ref")

      (base.keys - head.keys).each { |rel| FileUtils.rm_f(File.join(dir, rel)) }
      head.each { |rel, body| write.call(rel, body) }
      git.call("add -A")
      git.call("commit -q -m head")

      yield dir
    end
  end

  # A stub `bin/task` supporting the two calls the runner makes: `show <slug>
  # --json` and `update <slug> --checks <line>`. Backed by a JSON file so the test
  # can read what was actually recorded.
  def stub_task_bin(dir)
    store = File.join(dir, "task-store.json")
    File.write(store, JSON.generate("metadata" => { "devops" => { "checks_run" => [] } }))
    path = File.join(dir, "task-stub")
    File.write(path, <<~RUBY)
      #!/usr/bin/env ruby
      require "json"
      store = #{store.inspect}
      record = JSON.parse(File.read(store))
      case ARGV[0]
      when "show"
        puts JSON.generate(record)
      when "update"
        idx = ARGV.index("--checks")
        if idx
          record["metadata"]["devops"]["checks_run"] << ARGV[idx + 1]
          File.write(store, JSON.generate(record))
        end
      end
      exit 0
    RUBY
    FileUtils.chmod(0o755, path)
    [path, store]
  end

  # The stub CLI and its store live OUTSIDE the repo under test. Writing them
  # inside it would make the working tree dirty, and control-check (correctly)
  # refuses a dirty tree — the harness would have been testing its own mess.
  def run_control(dir, slug: "task-test", env: {})
    Dir.mktmpdir do |stub_dir|
      task_bin, store = stub_task_bin(stub_dir)
      base_env = SessionEnv.neutralized.merge(
        "CONTROL_CHECK_ROOT" => dir,
        "CONTROL_CHECK_DIFF_BASE" => "base-ref",
        "CONTROL_CHECK_TEST_CMD" => "grep -q NEWMARKER",
        "CONTROL_CHECK_SKIP_PREPARE" => "1",
        "CONTROL_CHECK_TASK_BIN" => task_bin
      ).merge(env)
      out = IO.popen(base_env, "#{BIN} #{slug} 2>&1", &:read)
      code = $?.exitstatus
      recorded = JSON.parse(File.read(store)).dig("metadata", "devops", "checks_run")
      return [out, code, recorded]
    end
  end

  def git_status(dir)
    IO.popen(["git", "-C", dir, "status", "--porcelain"], &:read).split("\n").map(&:strip).reject(&:empty?)
  end

  # --- the NECESSARY verdict (and the proof the swap landed) -----------------

  def test_replaying_a_pre_change_file_that_fails_yields_necessary
    with_repo(base: { "test/models/a_test.rb" => "OLD\n" },
              head: { "test/models/a_test.rb" => "NEWMARKER\n" }) do |dir|
      out, code, recorded = run_control(dir)

      assert_equal 0, code, out
      assert_includes out, "VERDICT: NECESSARY"
      # The load-bearing assertion: NECESSARY is only reachable if the replay ran
      # the OLD content. A no-op swap would have produced NO-SIGNAL here.
      assert_equal 1, recorded.size, "expected exactly one stamped control line"
      assert_match(/\A\[control@[0-9a-f]{7,64}\]/, recorded.first,
                   "the stamp must be fingerprint-bound machine-owned evidence, not a bare tag")
      assert_includes recorded.first, "NECESSARY"
      assert_includes recorded.first, "test/models/a_test.rb"
    end
  end

  def test_a_still_passing_pre_change_file_yields_no_signal
    # Both sides satisfy the stub command — a rename/consolidation/refactor looks
    # exactly like a quietly deleted assertion, which is the whole reason this
    # verdict does not refuse.
    with_repo(base: { "test/models/a_test.rb" => "NEWMARKER old\n" },
              head: { "test/models/a_test.rb" => "NEWMARKER new\n" }) do |dir|
      out, code, recorded = run_control(dir)

      assert_equal 0, code, out
      assert_includes out, "VERDICT: NO-SIGNAL"
      assert_includes recorded.first, "NO-SIGNAL"
      refute_includes out, "distinguishes nothing\ncontrol-check: ERROR"
    end
  end

  # --- the tree is restored, and PROVEN restored -----------------------------

  def test_the_harness_restores_the_working_tree
    with_repo(base: { "test/models/a_test.rb" => "OLD\n" },
              head: { "test/models/a_test.rb" => "NEWMARKER\n" }) do |dir|
      out, code, = run_control(dir)

      assert_equal 0, code, out
      assert_empty git_status(dir), "the harness left the working tree dirty"
      assert_equal "NEWMARKER\n", File.read(File.join(dir, "test/models/a_test.rb")),
                   "the harness left PRE-CHANGE content on disk — the builder's tree would be silently corrupted"
      assert_includes out, "tree restored and verified"
    end
  end

  def test_a_deleted_file_is_recreated_replayed_and_removed_again
    with_repo(base: { "test/models/a_test.rb" => "OLD\n", "test/models/keep_test.rb" => "NEWMARKER\n" },
              head: { "test/models/keep_test.rb" => "NEWMARKER\n" }) do |dir|
      out, code, recorded = run_control(dir)

      assert_equal 0, code, out
      assert_includes out, "VERDICT: NECESSARY"
      assert_includes recorded.first, "test/models/a_test.rb"
      refute File.exist?(File.join(dir, "test/models/a_test.rb")),
             "a file this diff DELETED must not survive the replay — the harness recreated it and must remove it"
      assert_empty git_status(dir)
    end
  end

  # --- the un-mechanizable half: no stamp is invented ------------------------

  def test_an_added_only_diff_stamps_nothing_and_says_so
    with_repo(base: {}, head: { "test/models/new_test.rb" => "NEWMARKER\n" }) do |dir|
      out, code, recorded = run_control(dir)

      assert_equal 0, code, out
      assert_empty recorded,
                   "an added file has NO pre-change version; stamping a control for a run that replayed " \
                   "nothing is the fake lane the e2e_onchain removal exists to warn against"
      assert_includes out, "nothing to replay"
      assert_includes out, "REVIEWER-PROMPT half"
    end
  end

  def test_an_e2e_only_diff_is_reported_as_deferred_not_replayed
    with_repo(base: { "e2e/upload.spec.js" => "OLD\n" },
              head: { "e2e/upload.spec.js" => "NEWMARKER\n" }) do |dir|
      out, code, recorded = run_control(dir)

      assert_equal 0, code, out
      assert_empty recorded
      assert_includes out, "deferred"
      assert_includes out, "e2e/upload.spec.js"
    end
  end

  # --- refusals that protect the builder -------------------------------------

  def test_refuses_a_dirty_tree_rather_than_destroying_uncommitted_work
    with_repo(base: { "test/models/a_test.rb" => "OLD\n" },
              head: { "test/models/a_test.rb" => "NEWMARKER\n" }) do |dir|
      File.write(File.join(dir, "test/models/a_test.rb"), "UNCOMMITTED WORK\n")
      out, code, recorded = run_control(dir)

      assert_equal 1, code
      assert_includes out, "working tree is dirty"
      assert_empty recorded
      assert_equal "UNCOMMITTED WORK\n", File.read(File.join(dir, "test/models/a_test.rb")),
                   "refusing must not touch the work it refused to run over"
    end
  end

  def test_refuses_an_unresolvable_diff_base
    with_repo(base: { "test/models/a_test.rb" => "OLD\n" },
              head: { "test/models/a_test.rb" => "NEWMARKER\n" }) do |dir|
      out, code, = run_control(dir, env: { "CONTROL_CHECK_DIFF_BASE" => "origin/nope" })

      assert_equal 1, code
      assert_includes out, "cannot resolve diff base"
    end
  end
end
