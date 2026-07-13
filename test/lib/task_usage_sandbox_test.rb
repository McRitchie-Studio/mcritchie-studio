# frozen_string_literal: true

# Unit cover for the fail-closed sandbox on the operator's real .agents state, and
# for the read-only audit that surfaces the rows a leak already left there.
#
#   ruby -Itest test/lib/task_usage_sandbox_test.rb
# Also picked up by the normal `bin/rails test` sweep.
#
# THE RULE UNDER TEST (lib/task_usage_sandbox.rb): with TASK_USAGE_SANDBOX on, a
# write to the usage/cost store or the session-marker store must be (1) PINNED by
# its env var — the fallback to <projects>/.agents is forbidden — and (2) OUTSIDE
# the real <projects>/.agents, whatever pointed it there.
#
# Rule 2 is proven against an INJECTED stand-in state dir. Proving it against the
# real one would mean asking the code to attempt the very write the guard exists
# to prevent, and a red run (or a broken fix) would then do the damage. The rule
# is a pure function of (path, state_dir), so the stand-in proves it exactly.

require "minitest/autorun"
require "json"
require "tmpdir"
require "fileutils"
require_relative "../support/session_env"
require_relative "../../lib/task_usage_sandbox"
require_relative "../../lib/task_usage_baseline"
require_relative "../../lib/task_usage_audit"

class TaskUsageSandboxTest < Minitest::Test
  ON = { "TASK_USAGE_SANDBOX" => "1", "TASK_USAGE_DIR" => "/tmp/pinned", "CLAUDE_PROJECTS_DIR" => "/tmp/pinned-projects" }.freeze

  # --- the sandbox switch ----------------------------------------------------

  def test_the_test_process_arms_the_sandbox_for_every_child_it_spawns
    # The load-bearing line in test/support/task_usage_sandbox.rb: requiring the
    # session-env helper (which every subprocess-spawning test already does) turns
    # the sandbox on process-wide, so a child inherits it WITHOUT being asked to.
    # A pin you have to remember is the bug; this is the half that cannot rot.
    assert TaskUsageSandbox.active?, "the test process must run with the sandbox armed"
  end

  def test_sandbox_is_inert_for_a_real_agent_run
    assert_nil TaskUsageSandbox.violation("/anywhere", store: "task-usage", env: {}),
               "an operator's real `bin/task move` must be untouched by the guard"
  end

  def test_an_explicit_off_switch_disarms_it
    %w[0 false no off].each do |off|
      refute TaskUsageSandbox.active?({ "TASK_USAGE_SANDBOX" => off }), "#{off.inspect} must read as off"
    end
  end

  # --- rule 1: PINNED (the actual bug) ---------------------------------------

  def test_an_unpinned_usage_store_is_a_violation
    env = { "TASK_USAGE_SANDBOX" => "1", "CLAUDE_PROJECTS_DIR" => "/tmp/p" } # TASK_USAGE_DIR absent
    message = TaskUsageSandbox.violation("/anywhere", store: "task-usage", env: env)

    refute_nil message, "an unset TASK_USAGE_DIR must be refused, not silently defaulted"
    assert_match(/TASK_USAGE_DIR/, message, "the refusal must name the var that pins the store")
  end

  def test_an_unpinned_marker_store_is_a_violation
    env = { "TASK_USAGE_SANDBOX" => "1", "TASK_USAGE_DIR" => "/tmp/u" } # CLAUDE_PROJECTS_DIR absent
    message = TaskUsageSandbox.violation("/anywhere", store: "session-marker", env: env)

    refute_nil message
    assert_match(/CLAUDE_PROJECTS_DIR/, message)
  end

  def test_a_blank_pin_does_not_count_as_pinned
    env = ON.merge("TASK_USAGE_DIR" => "   ")
    refute_nil TaskUsageSandbox.violation("/anywhere", store: "task-usage", env: env),
               "a whitespace pin is an unset pin — it still falls back to the real store"
  end

  # --- rule 2: OUTSIDE the real state dir ------------------------------------

  def test_a_pinned_path_inside_the_real_state_dir_is_still_a_violation
    Dir.mktmpdir do |root|
      state = File.join(root, ".agents") # stands in for <projects>/.agents
      inside = File.join(state, "task-usage")
      env = ON.merge("TASK_USAGE_DIR" => inside)

      message = TaskUsageSandbox.violation(inside, store: "task-usage", env: env, state_dir: state)
      refute_nil message, "a pin that points back INTO the real state dir is not a sandbox"
      assert_match(/#{Regexp.escape(state)}/, message, "the refusal must name the state dir it protected")
    end
  end

  def test_a_pinned_path_outside_the_real_state_dir_is_allowed
    Dir.mktmpdir do |root|
      state = File.join(root, ".agents")
      outside = File.join(root, "sandbox", "task-usage")

      assert_nil TaskUsageSandbox.violation(outside, store: "task-usage", env: ON.merge("TASK_USAGE_DIR" => outside),
                                                     state_dir: state)
    end
  end

  def test_a_sibling_path_is_not_read_as_inside_the_state_dir
    # ".../.agents-scratch" must not match ".../.agents" — the check is on a
    # separator boundary, not a string prefix.
    Dir.mktmpdir do |root|
      state = File.join(root, ".agents")
      sibling = File.join(root, ".agents-scratch")

      assert_nil TaskUsageSandbox.violation(sibling, store: "task-usage", env: ON.merge("TASK_USAGE_DIR" => sibling),
                                                     state_dir: state)
    end
  end

  # --- fail closed: the violation must ABORT, not degrade to a no-op ----------

  def test_enforce_aborts_rather_than_raising_a_rescuable_error
    # Every caller of this state is best-effort (`rescue StandardError => nil`), so
    # a violation raised as a StandardError would be SWALLOWED — the guard would go
    # quiet and the write would proceed. It must exit instead. SystemExit is not a
    # StandardError, which is exactly what carries it out through those rescues.
    error = assert_raises(SystemExit) do
      capture_io { TaskUsageSandbox.enforce!("/anywhere", store: "task-usage", env: { "TASK_USAGE_SANDBOX" => "1" }) }
    end
    refute_predicate error, :success?, "the abort must be a non-zero exit"

    swallowed = nil
    capture_io do
      swallowed = begin
        TaskUsageSandbox.enforce!("/anywhere", store: "task-usage", env: { "TASK_USAGE_SANDBOX" => "1" })
      rescue StandardError
        :swallowed
      rescue SystemExit
        :escaped
      end
    end
    assert_equal :escaped, swallowed, "a `rescue StandardError` must NOT be able to swallow a sandbox violation"
  end

  def test_the_baseline_store_is_guarded_at_its_write_choke_point
    # bin/task, bin/release and bin/reviewer-select all write through
    # TaskUsageBaseline#write, so the guard sits there too — a future caller that
    # resolves its own dir is sandboxed by construction, not by remembering to ask.
    Dir.mktmpdir do |root|
      state = File.join(root, ".agents")
      baseline = TaskUsageBaseline.new(session: "s1", dir: File.join(state, "task-usage"))

      assert_raises(SystemExit) do
        capture_io do
          with_env("TASK_USAGE_SANDBOX" => "1", "TASK_USAGE_DIR" => File.join(state, "task-usage")) do
            with_state_dir(state) { baseline.write("demo-task", "cache_read" => 1_941_377_119) }
          end
        end
      end
      assert_empty Dir.glob(File.join(state, "**", "*.json")), "the guard must abort BEFORE the write lands"
    end
  end

  def test_a_pinned_baseline_store_still_writes_normally
    Dir.mktmpdir do |root|
      dir = File.join(root, "usage")
      with_env("TASK_USAGE_SANDBOX" => "1", "TASK_USAGE_DIR" => dir) do
        TaskUsageBaseline.new(session: "s1", dir: dir).write("real-task", "cache_read" => 10)
      end

      assert_equal({ "cache_read" => 10 }, TaskUsageBaseline.new(session: "s1", dir: dir).read("real-task"),
                   "the sandbox must not break the store it protects")
    end
  end

  # --- the read-only audit ---------------------------------------------------

  def test_the_audit_surfaces_test_written_rows_and_leaves_the_store_alone
    Dir.mktmpdir do |dir|
      # The exact shape of the live pollution: a stub slug carrying a whole real
      # session's cumulative totals, sitting beside a legitimate row.
      file = File.join(dir, "2aa216f6-7565-4bf4-bd01-70793c8ba617.json")
      File.write(file, JSON.generate(
                         "demo-task" => { "input" => 505_407, "output" => 7_698_211,
                                          "cache_creation" => 30_387_379, "cache_read" => 1_941_377_119 },
                         "close-gate-system-test-gap" => { "input" => 969, "cache_read" => 120_288_371 }
                       ))
      before = File.read(file)

      rows = TaskUsageAudit.scan(dir)

      assert_equal ["demo-task"], rows.map(&:slug), "only the stub-slug row is reported"
      assert_equal ["fixture-slug"], rows.first.reasons
      assert_equal 1_941_377_119, rows.first.cache_read

      text, count = TaskUsageAudit.report(dir)
      assert_equal 1, count
      assert_match(/demo-task/, text)
      assert_match(/operator's call/, text, "the report must not present itself as a purge")

      assert_equal before, File.read(file),
                   "the audit is READ-ONLY — a purge is the operator's decision, never the tool's"
    end
  end

  # The lesson that cost this audit its first heuristic, pinned so it cannot come
  # back: a stored row is the session's CUMULATIVE totals at the moment it touched
  # the task, not that task's spend. A long real session banks a billion cached
  # tokens legitimately, so SIZE IS NOT EVIDENCE. Flagging on magnitude lit up ~80
  # genuine rows against the real store; only the stub slug is proof.
  def test_a_huge_baseline_on_a_real_slug_is_not_suspect
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "169e10db-4047-45aa-a359-3aeb04ac7cb9.json"),
                 JSON.generate("heartbeat-attribution-and-launchers" => { "cache_read" => 1_374_517_789 }))

      assert_empty TaskUsageAudit.scan(dir),
                   "a cumulative baseline is SUPPOSED to be huge — magnitude must never flag a real task"
    end
  end

  def test_the_audit_is_quiet_on_a_clean_store
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "019f0286-55c0-7232-a623-4c006f8f080d.json"),
                 JSON.generate("close-gate-system-test-gap" => { "cache_read" => 120_288_371 }))

      assert_empty TaskUsageAudit.scan(dir)
      assert_equal 0, TaskUsageAudit.report(dir).last
    end
  end

  def test_the_audit_catches_the_reviewer_select_stub_slug_too
    # bin/reviewer-select seeds a baseline at the review intent, and its test stub
    # answers with "cli-board-sample" — the second fixture slug in the real store,
    # and the one with the wider blast radius (dozens of live session files).
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "019f055f-3a3e-7d50-be3c-39ef793392bf.json"),
                 JSON.generate("cli-board-sample" => { "cache_read" => 20_744_704 }))

      assert_equal ["cli-board-sample"], TaskUsageAudit.scan(dir).map(&:slug)
    end
  end

  def test_the_audit_skips_junk_files_instead_of_raising
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "broken.json"), "{not json")
      File.write(File.join(dir, "array.json"), "[1,2,3]")

      assert_empty TaskUsageAudit.scan(dir), "an audit that raises on a stray file is an audit nobody runs"
    end
  end

  private

  def with_env(overrides)
    saved = overrides.keys.to_h { |key| [key, ENV.fetch(key, nil)] }
    overrides.each { |key, value| ENV[key] = value }
    yield
  ensure
    saved.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end

  # Swap the guard's notion of the real state dir for a stand-in, so the "inside the
  # real store" rule can be exercised without attempting a write into the operator's.
  def with_state_dir(dir)
    TaskUsageSandbox.singleton_class.send(:alias_method, :real_state_dir_without_stub, :real_state_dir)
    TaskUsageSandbox.define_singleton_method(:real_state_dir) { dir }
    yield
  ensure
    TaskUsageSandbox.define_singleton_method(:real_state_dir) do
      TaskUsageSandbox.real_state_dir_without_stub
    end
  end
end
