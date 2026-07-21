# frozen_string_literal: true

# [unit] tests for bin/devops-shift — the shift-lease CLI. The board behavior is
# covered by test/controllers/api/v1/devops_shifts_controller_test.rb; here we pin
# the CLI's own logic: exit-code branching on the acquire verdict, the held-shift
# marker, and the graceful no-session/no-lane fallbacks — with a fake API so no
# server is needed.
#
#   ruby -Itest test/lib/devops_shift_cli_test.rb

require "minitest/autorun"
require "json"
require "tmpdir"
require "fileutils"
require "stringio"
# Arms the narration-marker sandbox for this PROCESS (the sibling guarantee in
# test/support/task_usage_sandbox.rb). This file drives a CLI that WRITES the
# marker store, and it did not load this helper — so the guard was inert here and
# a forgetful stand-in could have written the operator's real ~/projects/.agents.
# An arming you have to remember is the bug; the test below ASSERTS it.
require_relative "../support/session_env"

load File.expand_path("../../bin/devops-shift", __dir__)

class DevopsShiftCliTest < Minitest::Test
  SESSION = "3bb327a7-8676-4cf5-ce12-81804d9cb728"

  Resp = Struct.new(:code, :body)

  # A stand-in for AgentApi that records POSTs and returns canned JSON. `data` is
  # the {data: …} payload every endpoint wraps its result in.
  class FakeApi
    attr_reader :posts

    def initialize(projects_dir:, data: {}, code: 200)
      @projects_dir = projects_dir
      @data = data
      @code = code
      @posts = []
    end

    def token = "tok"
    def projects_dir = @projects_dir

    # The stand-in must expose `env` exactly as AgentApi does: it is what RESOLVED
    # projects_dir, and the marker sandbox (bin/lib/session_markers.rb) evaluates
    # its "was the store pinned?" rule against THIS env — not the process ENV. So a
    # FakeApi that pins the tmpdir is a correctly-sandboxed caller, and the shift
    # marker writes there instead of the operator's real ~/projects/.agents.
    def env = { "CLAUDE_PROJECTS_DIR" => @projects_dir }
    def invalidate_token!(*) = nil
    def present?(value) = !value.to_s.strip.empty?

    def http_json(method, path, body = nil, **)
      @posts << { method: method, path: path, body: body }
      Resp.new(@code, JSON.generate({ data: @data }))
    end
  end

  # Every cli() gets a RECORDING spawner, so no test ever forks a real renewer, and
  # an explicit anchor pid, so anchor resolution never depends on whether the suite
  # happens to run under a `claude` process.
  def cli(env: {}, data: {}, code: 200, projects_dir:)
    c = DevopsShiftCli.new(env: { "DEVOPS_SHIFT_SESSION" => SESSION,
                                  "DEVOPS_SHIFT_ANCHOR_PID" => Process.pid.to_s }.merge(env),
                           out: (@out = StringIO.new), err: (@err = StringIO.new))
    c.instance_variable_set(:@api, FakeApi.new(projects_dir: projects_dir, data: data, code: code))
    @spawned = []
    c.instance_variable_set(:@spawner, ->(spawn_env, argv) { @spawned << [spawn_env, argv]; 4242 })
    c
  end

  def marker(projects_dir)
    File.join(projects_dir, ".agents", "sessions", "#{SESSION}.devops-shift")
  end

  def test_acquire_success_exits_zero_and_writes_the_marker
    Dir.mktmpdir do |proj|
      code = cli(projects_dir: proj, data: { "acquired" => true, "holder" => { "label" => "Exeggcute" } })
             .run(%w[acquire avi])
      assert_equal DevopsShiftCli::OK, code
      assert_match(/shift acquired/, @out.string)
      assert_equal "avi\n", File.read(marker(proj)), "the held-shift marker is written for the statusline renewer"
    end
  end

  # --- [unit] the narration-marker sandbox: an UNPINNED caller must fail closed --
  #
  # The .devops-shift marker lives in the same store as .open-activity/.acting-agent,
  # and resolved by the same CLAUDE_PROJECTS_DIR-else-real-projects-root fallback.
  # The FakeApi above pins a tmpdir, so these tests are safe BY CONVENTION — which
  # is exactly the pinning-by-convention that let the cost store leak (PR #525) and
  # the statusline heartbeat leak here. This is the assertion that a caller which
  # FORGETS now aborts instead of writing the operator's live narration store.
  #
  # The `abort` is SystemExit, not a StandardError, so it escapes write_marker's own
  # `rescue StandardError => nil` (which would otherwise degrade the guard to a
  # silent skip) AND DevopsShiftCli#run's top-level rescue. That is the point.
  # The guard is only as good as its arming, so assert the arming — do not trust it.
  def test_unit_this_process_arms_the_narration_marker_sandbox
    assert TaskUsageSandbox.active?,
           "this file drives a CLI that writes the marker store — it must run sandboxed"
  end

  def test_unit_an_unpinned_shift_marker_write_aborts_instead_of_reaching_the_real_store
    Dir.mktmpdir do |proj|
      c = cli(projects_dir: proj, data: { "acquired" => true, "holder" => {} })
      # The hole: a stand-in whose env pins NOTHING, while the suite has the sandbox
      # armed process-wide. projects_dir still points at the tmpdir here, so even a
      # regression cannot reach ~/projects — but the guard must refuse regardless,
      # because a real forgetful caller would have resolved the REAL root.
      unpinned = FakeApi.new(projects_dir: proj, data: { "acquired" => true, "holder" => {} })
      unpinned.define_singleton_method(:env) { {} }
      c.instance_variable_set(:@api, unpinned)

      original = $stderr
      $stderr = StringIO.new
      begin
        ex = assert_raises(SystemExit, "an unpinned marker write must ABORT, not be swallowed") do
          c.run(%w[acquire avi])
        end
        refute_predicate ex.status, :zero?, "the abort exits non-zero"
        assert_includes $stderr.string, "CLAUDE_PROJECTS_DIR", "and names the var to pin"
      ensure
        $stderr = original
      end

      refute_path_exists marker(proj), "a refused write creates nothing — the abort lands before any IO"
    end
  end

  def test_acquire_when_held_exits_stood_down_and_names_the_holder
    Dir.mktmpdir do |proj|
      code = cli(projects_dir: proj,
                 data: { "acquired" => false, "disposition" => "held_by_other",
                         "holder" => { "label" => "Exeggcute", "session" => "sess-A", "heartbeat_age" => 3 } })
             .run(%w[acquire avi])
      assert_equal DevopsShiftCli::STOOD_DOWN, code, "a held lane makes the second launch stand down (exit 10)"
      assert_match(/STAND DOWN/, @out.string)
      assert_match(/Exeggcute/, @out.string, "the step-down names the live holder")
      refute File.exist?(marker(proj)), "a stood-down session must NOT write a held-shift marker"
    end
  end

  def test_acquire_without_a_session_id_fails_open_not_wedged
    Dir.mktmpdir do |proj|
      code = cli(env: { "DEVOPS_SHIFT_SESSION" => "" }, projects_dir: proj).run(%w[acquire avi])
      assert_equal DevopsShiftCli::CANT_RUN, code, "no session id → fail open (exit 1), never a false hold"
    end
  end

  def test_acquire_without_a_lane_is_a_usage_error
    Dir.mktmpdir do |proj|
      assert_equal DevopsShiftCli::CANT_RUN, cli(projects_dir: proj).run(%w[acquire])
      assert_match(/needs a lane/, @err.string)
    end
  end

  def test_release_clears_the_marker_and_posts_release
    Dir.mktmpdir do |proj|
      FileUtils.mkdir_p(File.dirname(marker(proj)))
      File.write(marker(proj), "avi\n")
      c = cli(projects_dir: proj, data: { "released" => true })
      assert_equal DevopsShiftCli::OK, c.run(%w[release avi])
      refute File.exist?(marker(proj)), "release clears the held-shift marker"
      assert(c.instance_variable_get(:@api).posts.any? { |p| p[:path] == "/api/v1/devops_shifts/release" })
    end
  end

  # --- [unit] REGRESSION: acquire must arrange its OWN renewal -------------------
  #
  # Before this fix, the ONLY renewer was bin/statusline. A headless holder (a
  # background agent run, the autonomous heartbeat) therefore never renewed, its
  # lease lapsed one TTL after acquisition, and the lane read FREE to the next
  # session while the first was still working. Acquire now starts a renewer tied to
  # the run itself, so the guarantee no longer depends on a UI affordance.
  def test_unit_acquire_starts_a_renewer_so_a_headless_holder_keeps_the_lane
    Dir.mktmpdir do |proj|
      c = cli(projects_dir: proj, data: { "acquired" => true, "holder" => {} })
      assert_equal DevopsShiftCli::OK, c.run(%w[acquire avi])

      assert_equal 1, @spawned.length,
                   "acquire must start its own renewer — the status line is not always there"
      spawn_env, argv = @spawned.first
      assert_includes argv, "renew-loop", "the child runs the renewer command"
      assert_includes argv, "avi", "for the lane it just took"
      assert_includes argv, "--anchor-pid", "and is anchored to a process it can probe for liveness"
    end
  end

  # The renewer runs DETACHED, so it cannot re-derive the live-instance identity by
  # walking its own ancestry (it has been reparented away from the agent process).
  # If it guessed, `renew` would silently 204 forever and the lease would lapse
  # exactly as before — a renewer that runs but renews nothing. So identity is
  # handed down explicitly.
  def test_unit_the_renewer_inherits_the_live_instance_identity_explicitly
    Dir.mktmpdir do |proj|
      c = cli(projects_dir: proj, env: { "TASK_CLAIM_NONCE" => "inst-A" },
              data: { "acquired" => true, "holder" => {} })
      c.run(%w[acquire avi])

      spawn_env, = @spawned.first
      assert_equal SESSION, spawn_env["DEVOPS_SHIFT_SESSION"], "same session id as the holder"
      assert_equal "inst-A", spawn_env["TASK_CLAIM_NONCE"],
                   "same nonce — a renewer with a different nonce renews NOTHING and no-ops silently"
    end
  end

  def test_unit_a_stood_down_session_never_starts_a_renewer
    Dir.mktmpdir do |proj|
      c = cli(projects_dir: proj, data: { "acquired" => false, "holder" => { "label" => "Exeggcute" } })
      assert_equal DevopsShiftCli::STOOD_DOWN, c.run(%w[acquire avi])
      assert_empty @spawned, "you cannot renew a lease you were refused"
    end
  end

  # --- [unit] REGRESSION: release must report what the BOARD did -----------------
  #
  # Reported alongside the lease bug: `release` printed success unconditionally while
  # `status` kept showing the shift. The board answers 204 when the caller is NOT the
  # holder (so nothing was released) — release ignored that and claimed success, so
  # the two commands disagreed about one fact. Both now report from the board.
  def test_unit_release_the_board_refused_must_not_claim_success
    Dir.mktmpdir do |proj|
      c = cli(projects_dir: proj, code: 204, data: {})
      assert_equal DevopsShiftCli::OK, c.run(%w[release avi]), "release is still never a hard failure"
      refute_match(/shift released\./, @out.string,
                   "a 204 means NOTHING was released — saying otherwise is the lie status contradicts")
      assert_match(/not held by this session/i, @out.string, "and it says so plainly")
    end
  end

  def test_unit_release_that_the_board_honored_reports_success
    Dir.mktmpdir do |proj|
      c = cli(projects_dir: proj, code: 200, data: { "released" => true })
      assert_equal DevopsShiftCli::OK, c.run(%w[release avi])
      assert_match(/shift released\./, @out.string)
    end
  end

  def test_unit_release_stops_the_renewer_it_started
    Dir.mktmpdir do |proj|
      acquirer = cli(projects_dir: proj, data: { "acquired" => true, "holder" => {} })
      acquirer.run(%w[acquire avi])

      killed = []
      releaser = cli(projects_dir: proj, code: 200, data: { "released" => true })
      releaser.instance_variable_set(:@killer, ->(pid) { killed << pid })
      releaser.run(%w[release avi])

      assert_equal [4242], killed, "the renewer must not outlive the shift it was renewing"
    end
  end

  def test_renew_is_always_a_clean_exit_zero
    Dir.mktmpdir do |proj|
      assert_equal DevopsShiftCli::OK, cli(projects_dir: proj, data: { "renewed" => true }).run(%w[renew avi])
    end
  end

  def test_parse_flags_reads_label_value
    Dir.mktmpdir do |proj|
      flags = cli(projects_dir: proj).parse_flags(%w[--label Exeggcute])
      assert_equal "Exeggcute", flags["label"]
    end
  end
end
