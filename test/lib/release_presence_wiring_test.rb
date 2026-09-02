# frozen_string_literal: true

# THE WIRING: what `bin/release` actually publishes about THIS MACHINE while it works.
#
# Slice 4 of docs/agents/system/agent-presence.md. Standalone:
#   ruby -Itest test/lib/release_presence_wiring_test.rb
#
# DELIBERATELY A NEW FILE, not an addition to test/lib/release_cli_test.rb — the same
# rule test/lib/release_cli_accepted_gate_test.rb states: that file is ~7.6k lines,
# everyone appends at the bottom, so everyone conflicts at the bottom. It also carries a
# hard line ceiling, and appending these cases there tripped it (`rails (2)` red at 7674
# against a ceiling of 7598). The ceiling was right and the append was wrong.
#
# WHAT IS BEING PINNED, and why the module's own tests are not enough. The claim module
# (test/lib/release_presence_test.rb) proves the record and its grading. It cannot prove
# that `bin/release` ever calls it, or calls it around the right work — and the wiring is
# what the task exists to do. The board `assembler` claim already answers "is a release
# live" REMOTELY; this is the LOCAL twin, and it is the only fact that decides whether the
# agent at the next desk may launch a suite. Measured cost of its absence: a 45-minute
# full-suite run SIGTERMed at its 2700s ceiling, 11% complete, killed by a sweep no status
# command reported.
#
# OBSERVED FROM INSIDE THE WORK, never asserted about the source. Each case stubs `sh` to
# READ THE CLAIM OFF DISK at the moment the wrapped command runs, so a case can only pass
# if the transition is actually in force while the work happens. A grep of bin/release.rb
# would pass against a transition that never fires AND against one that never restores.

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "open3"
require "rbconfig"

class ReleasePresenceWiringTest < Minitest::Test
  BIN = File.expand_path("../../bin/release.rb", __dir__)

  # A captured narration channel plus an open role span, which is the exact gating
  # `step()` rides — without it `scope_action` never fires and the scope wrapper would be
  # exercised in a shape the real conductor never runs.
  SCOPE_EMIT_STUB = <<~RUBY
    $events = []
    def agent_activity(*a) = ($events << a)
    def conductor_session_id = "sess-x"
    $role_span_open = true
  RUBY

  def setup
    @lock_dir = Dir.mktmpdir("presence-wiring-locks")
  end

  def teardown
    FileUtils.remove_entry(@lock_dir) if @lock_dir && File.directory?(@lock_dir)
  end

  # Run a bin/release entrypoint in a clean subprocess. ARGV is set BEFORE `load`
  # because DRY/PROD are read from it at load time. MCR_PRIMARY_LOCK_DIR is pinned at a
  # per-test tmpdir: the real dir belongs to the live conductor, and a test that flocks it
  # while a G3 gate holds it for a whole suite would deadlock that gate against itself.
  def run_cli(setup:, call:)
    script = %(ARGV.replace(["--yes"]); load #{BIN.inspect}\n#{setup}\n#{call})
    env = { "MCR_PRIMARY_LOCK_DIR" => @lock_dir, "TASK_API_BASE" => "http://127.0.0.1:9" }
    out, err, status = Open3.capture3(env, RbConfig.ruby, "-e", script)

    assert_predicate status, :success?, "the bin/release child exited nonzero: #{err}"
    out
  end

  def test_run_test_scope_publishes_the_suite_weight_for_exactly_its_duration
    Dir.mktmpdir do |root|
      lock = %(CertOrphanGuard.lock_path(#{root.inspect}))
      setup = SCOPE_EMIT_STUB + <<~RUBY
        ReleasePresence.open!(kind: ReleasePresence::SWEEP, root: #{root.inspect},
                              lane: "release:prepare")
        def sh(*_a, **_k) = [File.read(#{lock}), true]
      RUBY
      call = <<~RUBY
        inside, _ok = run_test_scope("pre_qa_gate", "bin/rails", "test",
                                     capture: true, repo: "mcritchie-studio")
        print("INSIDE=" + inside + 10.chr + "AFTER=" + File.read(#{lock}))
      RUBY
      out = run_cli(setup: setup, call: call)

      assert_match(/INSIDE=.*"weight":"suite"/, out,
                   "while a release gate's suite is RUNNING the claim must cost a full suite — " \
                   "this is the phase that saturated the machine and killed a 45-minute run, and " \
                   "run_test_scope is the choke point every conductor gate passes through, so one " \
                   "wrap covers the G3 pre-QA gate and the ship's frozen-SHA gate alike")
      assert_match(/AFTER=.*"weight":"light"/, out,
                   "and it must fall back afterwards. A claim stranded at suite weight would wedge " \
                   "every peer for the rest of the sweep — the design tolerates a DEAD writer's " \
                   "stale phase, bounded by its own lifetime, never a live writer's bookkeeping")
    end
  end

  def test_the_ci_poll_publishes_the_waiting_phase_so_a_parked_conductor_costs_nothing
    Dir.mktmpdir do |root|
      lock = %(CertOrphanGuard.lock_path(#{root.inspect}))
      setup = SCOPE_EMIT_STUB + <<~RUBY
        ReleasePresence.open!(kind: ReleasePresence::SHIP, root: #{root.inspect},
                              lane: "release:ship")
        $seen = nil
        def sh(*_a, **_k)
          $seen = File.read(#{lock})
          ["completed" + 9.chr + "success", true]
        end
      RUBY
      call = <<~RUBY
        ok = run_concluded_success?("42")
        print("OK=" + ok.to_s + 10.chr + "SEEN=" + $seen.to_s + 10.chr + "AFTER=" + File.read(#{lock}))
      RUBY
      out = run_cli(setup: setup, call: call)

      assert_match(/OK=true/, out, "the poll's verdict must be unchanged by the presence wrapper")
      assert_match(/SEEN=.*"phase":"waiting"/, out,
                   "a conductor asleep on a GitHub Actions poll consumes nothing. That is cost #4 " \
                   "of the design — two idle processes read as competing certs and nearly held off " \
                   "a launch — and `waiting` is the field the reader already short-circuits to " \
                   "weight 0 while STILL counting the claim, so the process group stays attributed " \
                   "instead of falling back into the backstop")
      assert_match(/AFTER=.*"phase":"working"/, out,
                   "and the conductor is working again the moment the poll returns")
    end
  end

  def test_a_release_gate_runs_normally_when_presence_is_disarmed
    setup = SCOPE_EMIT_STUB + <<~RUBY
      ENV["RELEASE_PRESENCE"] = "off"
      def sh(*_a, **_k) = ["9 runs, 9 assertions, 0 failures, 0 errors", true]
    RUBY
    call = <<~RUBY
      _o, ok = run_test_scope("pre_qa_gate", "bin/rails", "test", repo: "mcritchie-studio")
      print("OK=" + ok.to_s + " EVENTS=" + $events.size.to_s)
    RUBY
    out = run_cli(setup: setup, call: call)

    assert_includes out, "OK=true",
                    "RELEASE_PRESENCE=off must leave the release itself untouched — a presence " \
                    "writer that can change a deploy's outcome is worse than no writer"
    refute_includes out, "EVENTS=0", "…and the gate's own telemetry still fires"
  end
end
