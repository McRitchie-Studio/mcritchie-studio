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
# what the task exists to do.
#
# ASSERTED AS HEADROOM, NOT AS A WEIGHT STRING. Every case here runs the REAL reader
# (`AgentPresence.snapshot`) from INSIDE the wrapped work and reports the number a peer
# standing at the next desk would read before deciding whether to launch a suite. That
# choice is deliberate: a weight is a constant, and a test that asserts a constant passes
# in BOTH directions the moment somebody changes the constant and the expectation
# together. Headroom is an OBSERVATION — it can only be produced by a claim that is on
# disk, live, correctly graded, and correctly weighted at the instant the work runs.
#
# The capacity is AgentPresence::DEFAULT_SUITE_CAPACITY = 3.00 suites, so the numbers
# these cases pin are:
#
#   conductor working, no scope   light 0.25   headroom 2.75
#   inside a LOCAL suite          suite 1.00   headroom 2.00
#   inside a REMOTE smoke/hook    light 0.25   headroom 2.75   ← the fix
#   inside the repo_script deploy suite 1.00   headroom 2.00   ← the fix
#
# OBSERVED FROM INSIDE THE WORK, never asserted about the source. Each case stubs `sh` to
# take the reading at the moment the wrapped command runs, so a case can only pass if the
# transition is actually in force while the work happens. A grep of bin/release.rb would
# pass against a transition that never fires AND against one that never restores.

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "open3"
require "rbconfig"
require_relative "../../bin/lib/agent_presence"

class ReleasePresenceWiringTest < Minitest::Test
  BIN = File.expand_path("../../bin/release.rb", __dir__)

  # The three headroom readings this whole file is about, named once.
  FREE  = format("%.2f", AgentPresence::DEFAULT_SUITE_CAPACITY)                 # 3.00
  LIGHT = format("%.2f", AgentPresence::DEFAULT_SUITE_CAPACITY - 0.25)          # 2.75
  SUITE = format("%.2f", AgentPresence::DEFAULT_SUITE_CAPACITY - 1.0)           # 2.00

  # A captured narration channel plus an open role span, which is the exact gating
  # `step()` rides — without it `scope_action` never fires and the scope wrapper would be
  # exercised in a shape the real conductor never runs. `observe` is THE READER: the
  # shipped `AgentPresence.snapshot`, not a restatement of its arithmetic.
  PRELUDE = <<~RUBY
    $events = []
    def agent_activity(*a) = ($events << a)
    def conductor_session_id = "sess-x"
    $role_span_open = true
    require #{File.expand_path("../../bin/lib/agent_presence", __dir__).inspect}
    def observe
      format("%.2f", AgentPresence.snapshot(root: ENV.fetch("CLAUDE_PROJECTS_DIR"), load: nil)[:headroom])
    end
  RUBY

  def setup
    @lock_dir = Dir.mktmpdir("presence-wiring-locks")
    @store    = Dir.mktmpdir("presence-wiring-store")
  end

  def teardown
    [@lock_dir, @store].each { |d| FileUtils.remove_entry(d) if d && File.directory?(d) }
  end

  # Run a bin/release entrypoint in a clean subprocess. ARGV is set BEFORE `load`
  # because DRY/PROD are read from it at load time. MCR_PRIMARY_LOCK_DIR is pinned at a
  # per-test tmpdir: the real dir belongs to the live conductor, and a test that flocks it
  # while a G3 gate holds it for a whole suite would deadlock that gate against itself.
  # CLAUDE_PROJECTS_DIR pins the MARKER STORE the same way — the claim must never land in
  # the operator's live `.agents`, and pinning it here also exercises the exact default
  # resolution `bin/release` itself uses (PresenceClaim.projects_dir_from).
  def run_cli(setup:, call:)
    script = %(ARGV.replace(["--yes"]); load #{BIN.inspect}\n#{setup}\n#{call})
    env = { "MCR_PRIMARY_LOCK_DIR" => @lock_dir, "TASK_API_BASE" => "http://127.0.0.1:9",
            "CLAUDE_PROJECTS_DIR" => @store, "TASK_USAGE_SANDBOX" => "0" }
    out, err, status = Open3.capture3(env, RbConfig.ruby, "-e", script)

    assert_predicate status, :success?, "the bin/release child exited nonzero: #{err}"
    out
  end

  def sweep_open(kind: "SWEEP", lane: "release:prepare")
    <<~RUBY
      ReleasePresence.open!(kind: ReleasePresence::#{kind}, root: #{@store.inspect},
                            lane: #{lane.inspect})
    RUBY
  end

  # --- the local lanes: this box pays, and a peer must be told so ---------------------

  def test_a_local_gate_costs_a_full_suite_for_exactly_its_duration
    setup = PRELUDE + sweep_open + <<~RUBY
      def sh(*_a, **_k) = [observe, true]
    RUBY
    call = <<~RUBY
      inside, _ok = run_test_scope("pre_qa_gate", "bin/rails", "test",
                                   capture: true, repo: "mcritchie-studio")
      print("INSIDE=" + inside + " AFTER=" + observe)
    RUBY
    out = run_cli(setup: setup, call: call)

    assert_includes out, "INSIDE=#{SUITE}",
                    "while a release gate's LOCAL suite is running, a peer must read only " \
                    "#{SUITE} suites of headroom. This is the phase that saturated the machine " \
                    "and killed a 45-minute run, and run_test_scope is the choke point every " \
                    "conductor gate passes through, so one wrap covers the G3 pre-QA gate and " \
                    "the ship's frozen-SHA gate alike"
    assert_includes out, "AFTER=#{LIGHT}",
                    "and the machine must come back. A claim stranded at suite weight would " \
                    "wedge every peer for the rest of the sweep — the design tolerates a DEAD " \
                    "writer's stale phase, bounded by its own lifetime, never a live writer's " \
                    "bookkeeping"
  end

  # --- the remote lanes: another machine pays, and saying otherwise costs a peer ------

  # THE BUG THIS PR FOLDS IN. `run_test_scope` published WEIGHT_SUITE for every scope it
  # wrapped, so four of the eight registered scopes told a peer this box was three times
  # busier than it was. All four are the `host != local` ones: two `/up` curl polls and two
  # `heroku run` post-deploy hooks, where a Heroku dyno does the work and this process
  # holds a socket. Over-reporting is the cheaper direction of wrong, but it is still
  # wrong, and it is measured here as the number a peer actually reads.
  def test_a_remotely_executed_scope_does_not_claim_this_box_is_busy
    %w[qa_up_smoke qa_post_deploy prod_up_smoke prod_post_deploy].each do |scope|
      setup = PRELUDE + sweep_open + <<~RUBY
        def sh(*_a, **_k) = [observe, true]
      RUBY
      call = <<~RUBY
        inside, _ok = run_test_scope(#{scope.inspect}, "curl", "-s", capture: true, repo: "mcritchie-studio")
        print("INSIDE=" + inside)
      RUBY
      out = run_cli(setup: setup, call: call)

      assert_includes out, "INSIDE=#{LIGHT}",
                      "#{scope} runs on a Heroku dyno, not here — a peer must still read " \
                      "#{LIGHT} suites of headroom while it runs. Publishing #{SUITE} tells " \
                      "the agent at the next desk to wait out a `curl`, which is the same " \
                      "class of wrong answer as the silence this module was built to fix"
    end
  end

  # `host:` names the TARGET, not the payer — and the rule has to know the difference.
  # `prod_smoke_seal` is `host: production` and runs `npx playwright test` on THIS box
  # (bin/prod-smoke:77), so it costs a full suite. A rule keyed on `host` alone would get
  # this one backwards, which is why the derivation reads `tier` too.
  def test_a_locally_driven_suite_against_a_remote_target_still_costs_this_box
    setup = PRELUDE + sweep_open(kind: "SHIP", lane: "release:ship") + <<~RUBY
      def sh(*_a, **_k) = [observe, true]
    RUBY
    call = <<~RUBY
      inside, _ok = run_test_scope("prod_smoke_seal", "bin/prod-smoke", capture: true, repo: "mcritchie-studio")
      print("INSIDE=" + inside)
    RUBY
    out = run_cli(setup: setup, call: call)

    assert_includes out, "INSIDE=#{SUITE}",
                    "bin/prod-smoke drives playwright LOCALLY against a production URL. " \
                    "`host: production` describes where it points, not who pays"
  end

  # --- the deploy that no registry row can reach --------------------------------------

  # THE HEAVIEST LOCAL WORKLOAD THE SHIP CREATES, and it published `light` for its whole
  # duration. The `repo_script` deploy does not pass through `run_test_scope` at all — it
  # is a deploy, not a registered test scope — so fixing the registry could never reach it
  # and it needed its own explicit wrap. turf-monster's `bin/deploy` runs `bin/rails test`
  # INSIDE this call.
  def test_the_repo_script_deploy_costs_a_full_suite_although_no_scope_wraps_it
    setup = PRELUDE + sweep_open(kind: "SHIP", lane: "release:ship") + <<~RUBY
      # Everything deploy_app touches that would reach git, the network or the board.
      # The deploy CALL itself is left alone — it is the subject.
      def push_frozen_main(*_a) = nil
      def record_merged_main(*_a) = nil
      def repo_path(_r) = #{@store.inspect}
      def with_ship_workspace(_repo) = yield
      def ship_workspace!(_repo, _sha) = #{@store.inspect}
      def prepare_ship_workspace!(*_a) = nil
      def ship_deploy_env(_repo) = {}
      def gate_sop(*_a) = nil
      $seen = nil
      def sh(*a, **_k)
        $seen = observe if a.first == "bin/deploy"
        ["", true]
      end
    RUBY
    call = <<~RUBY
      deploy_app({ "repo" => "turf-monster", "members" => [],
                   "prod_deploy" => { "strategy" => "repo_script", "command" => "bin/deploy" } },
                 "0" * 40)
      print("INSIDE=" + $seen.to_s + " AFTER=" + observe)
    RUBY
    out = run_cli(setup: setup, call: call)

    assert_includes out, "INSIDE=#{SUITE}",
                    "a peer must read #{SUITE} while the repo's own deploy script runs its " \
                    "suite. Publishing the conductor's ambient #{LIGHT} here said the machine " \
                    "was three-quarters free at the exact moment it was busiest"
    assert_includes out, "AFTER=#{LIGHT}",
                    "and the conductor drops back to its ambient cost once the deploy returns"
  end

  # --- the phases that cost nothing, and the disarm ------------------------------------

  def test_the_ci_poll_publishes_the_waiting_phase_so_a_parked_conductor_costs_nothing
    setup = PRELUDE + sweep_open(kind: "SHIP", lane: "release:ship") + <<~RUBY
      $seen = nil
      def sh(*_a, **_k)
        $seen = observe
        ["completed" + 9.chr + "success", true]
      end
    RUBY
    call = <<~RUBY
      ok = run_concluded_success?("42")
      print("OK=" + ok.to_s + " SEEN=" + $seen.to_s + " AFTER=" + observe)
    RUBY
    out = run_cli(setup: setup, call: call)

    assert_includes out, "OK=true", "the poll's verdict must be unchanged by the presence wrapper"
    assert_includes out, "SEEN=#{FREE}",
                    "a conductor asleep on a GitHub Actions poll consumes NOTHING — a peer must " \
                    "read the machine as fully free. That is cost #4 of the design: two idle " \
                    "processes read as competing certs and nearly held off a launch. The claim " \
                    "is still COUNTED (phase `waiting` short-circuits to weight 0), so the " \
                    "process group stays attributed instead of falling into the backstop"
    assert_includes out, "AFTER=#{LIGHT}",
                    "and the conductor is working again the moment the poll returns"
  end

  def test_a_release_gate_runs_normally_when_presence_is_disarmed
    setup = PRELUDE + <<~RUBY
      ENV["RELEASE_PRESENCE"] = "off"
      def sh(*_a, **_k) = ["9 runs, 9 assertions, 0 failures, 0 errors", true]
    RUBY
    call = <<~RUBY
      _o, ok = run_test_scope("pre_qa_gate", "bin/rails", "test", repo: "mcritchie-studio")
      print("OK=" + ok.to_s + " EVENTS=" + $events.size.to_s + " HEADROOM=" + observe)
    RUBY
    out = run_cli(setup: setup, call: call)

    assert_includes out, "OK=true",
                    "RELEASE_PRESENCE=off must leave the release itself untouched — a presence " \
                    "writer that can change a deploy's outcome is worse than no writer"
    refute_includes out, "EVENTS=0", "…and the gate's own telemetry still fires"
    assert_includes out, "HEADROOM=#{FREE}", "…while publishing nothing at all"
  end
end
