# frozen_string_literal: true

# [unit] tests for the `bin/task review-claim` CLI (ReviewClaimCli). The board
# behavior is covered by test/controllers/api/v1/task_review_claims_controller_test.rb;
# here we pin the CLI's own logic: exit-code branching on the acquire verdict, the
# held-review marker, the detached renewer, and the graceful no-session/no-slug
# fallbacks — with a fake API so no server is needed.
#
#   ruby -Itest test/lib/review_claim_cli_test.rb

require "minitest/autorun"
require "json"
require "tmpdir"
require "fileutils"
require "stringio"
# Arms the narration-marker sandbox for this PROCESS (the sibling guarantee in
# test/support/task_usage_sandbox.rb). This file drives a CLI that WRITES the marker
# store, so the guard must be armed or a forgetful stand-in could write the operator's
# real ~/projects/.agents. An arming you have to remember is the bug; a test asserts it.
require_relative "../support/session_env"

load File.expand_path("../../bin/lib/review_claim_cli.rb", __dir__)

class ReviewClaimCliTest < Minitest::Test
  SESSION = "3bb327a7-8676-4cf5-ce12-81804d9cb728"
  SLUG = "task-review-me"

  Resp = Struct.new(:code, :body)

  # A stand-in for AgentApi that records POSTs and returns canned JSON. `data` is the
  # {data: …} payload every endpoint wraps its result in.
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
    # projects_dir, and the marker sandbox evaluates its "was the store pinned?" rule
    # against THIS env — so a FakeApi that pins the tmpdir is correctly sandboxed and
    # the review marker writes there instead of the operator's real ~/projects/.agents.
    def env = { "CLAUDE_PROJECTS_DIR" => @projects_dir }
    def invalidate_token!(*) = nil
    def present?(value) = !value.to_s.strip.empty?

    def http_json(method, path, body = nil, **)
      @posts << { method: method, path: path, body: body }
      Resp.new(@code, JSON.generate({ data: @data }))
    end
  end

  # Every cli() gets a RECORDING spawner, so no test ever forks a real renewer, and an
  # explicit anchor pid, so anchor resolution never depends on whether the suite runs
  # under a `claude` process.
  def cli(env: {}, data: {}, code: 200, projects_dir:)
    c = ReviewClaimCli.new(env: { "TASK_REVIEW_CLAIM_SESSION" => SESSION,
                                  "TASK_REVIEW_CLAIM_ANCHOR_PID" => Process.pid.to_s }.merge(env),
                           out: (@out = StringIO.new), err: (@err = StringIO.new))
    c.instance_variable_set(:@api, FakeApi.new(projects_dir: projects_dir, data: data, code: code))
    @spawned = []
    c.instance_variable_set(:@spawner, ->(spawn_env, argv) { @spawned << [spawn_env, argv]; 4242 })
    c
  end

  def marker(projects_dir, slug = SLUG)
    File.join(projects_dir, ".agents", "sessions", "#{SESSION}.task-review-claim-#{slug}")
  end

  def renewer_marker(projects_dir, slug)
    File.join(projects_dir, ".agents", "sessions", "#{SESSION}.task-review-claim-renewer-#{slug}")
  end

  def test_acquire_success_exits_zero_and_writes_the_marker
    Dir.mktmpdir do |proj|
      code = cli(projects_dir: proj, data: { "acquired" => true, "holder" => { "label" => "Gastly" } })
             .run(["acquire", SLUG])
      assert_equal ReviewClaimCli::OK, code
      assert_match(/review claimed/, @out.string)
      assert_equal "#{SLUG}\n", File.read(marker(proj)), "the held-review marker records the slug for release"
    end
  end

  # An UNPINNED caller must fail closed — the .task-review-claim marker lives in the
  # same store as .devops-shift/.open-activity. This asserts a caller which FORGETS to
  # pin aborts instead of writing the operator's live narration store.
  def test_unit_this_process_arms_the_narration_marker_sandbox
    assert TaskUsageSandbox.active?,
           "this file drives a CLI that writes the marker store — it must run sandboxed"
  end

  def test_unit_an_unpinned_marker_write_aborts_instead_of_reaching_the_real_store
    Dir.mktmpdir do |proj|
      c = cli(projects_dir: proj, data: { "acquired" => true, "holder" => {} })
      unpinned = FakeApi.new(projects_dir: proj, data: { "acquired" => true, "holder" => {} })
      unpinned.define_singleton_method(:env) { {} }
      c.instance_variable_set(:@api, unpinned)

      original = $stderr
      $stderr = StringIO.new
      begin
        ex = assert_raises(SystemExit, "an unpinned marker write must ABORT, not be swallowed") do
          c.run(["acquire", SLUG])
        end
        refute_predicate ex.status, :zero?, "the abort exits non-zero"
        assert_includes $stderr.string, "CLAUDE_PROJECTS_DIR", "and names the var to pin"
      ensure
        $stderr = original
      end

      refute_path_exists marker(proj), "a refused write creates nothing — the abort lands before any IO"
    end
  end

  def test_acquire_when_under_review_exits_skipped_and_names_the_reviewer
    Dir.mktmpdir do |proj|
      code = cli(projects_dir: proj,
                 data: { "acquired" => false, "disposition" => "held_by_other",
                         "holder" => { "label" => "Gastly", "session" => "sess-A", "heartbeat_age" => 3 } })
             .run(["acquire", SLUG])
      assert_equal ReviewClaimCli::SKIPPED, code, "a task under review makes the second session skip (exit 10)"
      assert_match(/SKIP/, @out.string)
      assert_match(/Gastly/, @out.string, "the skip message names the live reviewer")
      refute File.exist?(marker(proj)), "a skipped session must NOT write a held-review marker"
    end
  end

  def test_acquire_without_a_session_id_fails_open_not_wedged
    Dir.mktmpdir do |proj|
      code = cli(env: { "TASK_REVIEW_CLAIM_SESSION" => "" }, projects_dir: proj).run(["acquire", SLUG])
      assert_equal ReviewClaimCli::CANT_RUN, code, "no session id → fail open (exit 1), never a false claim"
    end
  end

  def test_acquire_without_a_slug_is_a_usage_error
    Dir.mktmpdir do |proj|
      assert_equal ReviewClaimCli::CANT_RUN, cli(projects_dir: proj).run(%w[acquire])
      assert_match(/needs a task slug/, @err.string)
    end
  end

  def test_release_clears_the_marker_and_posts_release
    Dir.mktmpdir do |proj|
      FileUtils.mkdir_p(File.dirname(marker(proj)))
      File.write(marker(proj), "#{SLUG}\n")
      c = cli(projects_dir: proj, data: { "released" => true })
      assert_equal ReviewClaimCli::OK, c.run(["release", SLUG])
      refute File.exist?(marker(proj)), "release clears the held-review marker"
      assert(c.instance_variable_get(:@api).posts.any? { |p| p[:path] == "/api/v1/tasks/#{SLUG}/review_claim/release" })
    end
  end

  # --- [unit] acquire must arrange its OWN renewal ------------------------------
  # A headless pr-review supervisor paints no status line, so the ONLY thing keeping
  # its review alive is a renewer tied to the run itself. Acquire starts one.
  def test_unit_acquire_starts_a_renewer_so_a_headless_reviewer_keeps_the_task
    Dir.mktmpdir do |proj|
      c = cli(projects_dir: proj, data: { "acquired" => true, "holder" => {} })
      assert_equal ReviewClaimCli::OK, c.run(["acquire", SLUG])

      assert_equal 1, @spawned.length,
                   "acquire must start its own renewer — the status line is not always there"
      _spawn_env, argv = @spawned.first
      assert_includes argv, "renew-loop", "the child runs the renewer command"
      assert_includes argv, SLUG, "for the task it just claimed"
      assert_includes argv, "--anchor-pid", "and is anchored to a process it can probe for liveness"
    end
  end

  # The renewer runs DETACHED, so it cannot re-derive the live-instance identity by
  # walking its own ancestry. If it guessed, `renew` would silently 204 forever and the
  # lease would lapse. So identity is handed down explicitly.
  def test_unit_the_renewer_inherits_the_live_instance_identity_explicitly
    Dir.mktmpdir do |proj|
      c = cli(projects_dir: proj, env: { "TASK_CLAIM_NONCE" => "inst-A" },
              data: { "acquired" => true, "holder" => {} })
      c.run(["acquire", SLUG])

      spawn_env, = @spawned.first
      assert_equal SESSION, spawn_env["TASK_REVIEW_CLAIM_SESSION"], "same session id as the reviewer"
      assert_equal "inst-A", spawn_env["TASK_CLAIM_NONCE"],
                   "same nonce — a renewer with a different nonce renews NOTHING and no-ops silently"
    end
  end

  def test_unit_a_skipped_session_never_starts_a_renewer
    Dir.mktmpdir do |proj|
      c = cli(projects_dir: proj, data: { "acquired" => false, "holder" => { "label" => "Gastly" } })
      assert_equal ReviewClaimCli::SKIPPED, c.run(["acquire", SLUG])
      assert_empty @spawned, "you cannot renew a review you were refused"
    end
  end

  def test_unit_release_that_the_board_refused_must_not_claim_success
    Dir.mktmpdir do |proj|
      c = cli(projects_dir: proj, code: 204, data: {})
      assert_equal ReviewClaimCli::OK, c.run(["release", SLUG]), "release is still never a hard failure"
      refute_match(/review released\./, @out.string,
                   "a 204 means NOTHING was released — saying otherwise is a lie status would contradict")
      assert_match(/not under review by this session/i, @out.string, "and it says so plainly")
    end
  end

  def test_unit_release_that_the_board_honored_reports_success
    Dir.mktmpdir do |proj|
      c = cli(projects_dir: proj, code: 200, data: { "released" => true })
      assert_equal ReviewClaimCli::OK, c.run(["release", SLUG])
      assert_match(/review released\./, @out.string)
    end
  end

  def test_unit_release_stops_the_renewer_it_started
    Dir.mktmpdir do |proj|
      acquirer = cli(projects_dir: proj, data: { "acquired" => true, "holder" => {} })
      acquirer.run(["acquire", SLUG])

      killed = []
      releaser = cli(projects_dir: proj, code: 200, data: { "released" => true })
      releaser.instance_variable_set(:@killer, ->(pid) { killed << pid })
      releaser.run(["release", SLUG])

      assert_equal [4242], killed, "the renewer must not outlive the review it was renewing"
    end
  end

  # A --fast wave claims SEVERAL tasks in ONE session before releasing any, so each
  # claim's renewer must be tracked independently. A per-SESSION marker would make
  # release(taskA) read and kill taskB's renewer pid → taskB lapses mid-review and a
  # second session could claim it (the double-review this gate exists to prevent).
  # Markers are keyed per (session, slug): releasing one leaves the other's renewer.
  def test_unit_concurrent_claims_in_one_session_track_renewers_independently
    Dir.mktmpdir do |proj|
      a = cli(projects_dir: proj, data: { "acquired" => true, "holder" => {} })
      a.instance_variable_set(:@spawner, ->(_env, _argv) { 111 })
      a.run(["acquire", "task-a"])

      b = cli(projects_dir: proj, data: { "acquired" => true, "holder" => {} })
      b.instance_variable_set(:@spawner, ->(_env, _argv) { 222 })
      b.run(["acquire", "task-b"])

      assert_path_exists renewer_marker(proj, "task-a"), "task-a's renewer is tracked"
      assert_path_exists renewer_marker(proj, "task-b"), "task-b's renewer is tracked separately"

      killed = []
      releaser = cli(projects_dir: proj, code: 200, data: { "released" => true })
      releaser.instance_variable_set(:@killer, ->(pid) { killed << pid })
      releaser.run(["release", "task-a"])

      assert_equal [111], killed, "releasing task-a kills ONLY task-a's renewer, never task-b's"
      refute_path_exists renewer_marker(proj, "task-a"), "task-a's renewer marker is cleared"
      assert_path_exists renewer_marker(proj, "task-b"), "task-b's renewer survives task-a's release"
    end
  end

  def test_renew_is_always_a_clean_exit_zero
    Dir.mktmpdir do |proj|
      assert_equal ReviewClaimCli::OK, cli(projects_dir: proj, data: { "renewed" => true }).run(["renew", SLUG])
    end
  end

  def test_parse_flags_reads_label_value
    Dir.mktmpdir do |proj|
      flags = cli(projects_dir: proj).parse_flags(%w[--label Gastly])
      assert_equal "Gastly", flags["label"]
    end
  end

  # --- [unit] claim-next-review: the ATOMIC server pop --------------------------
  # The server picks WHICH task (highest-ranked reviewable green-CI) and claims it in
  # one request; the CLI just relays. On success it prints JUST the slug (so a caller
  # can `slug=$(bin/task claim-next-review)`) and, like acquire, anchors a renewer.
  def test_unit_claim_next_prints_the_slug_writes_the_marker_and_starts_a_renewer
    Dir.mktmpdir do |proj|
      c = cli(projects_dir: proj,
              data: { "claimed" => { "slug" => "popped-task" }, "holder" => { "label" => "Gastly" } })
      code = c.run(["claim-next"])

      assert_equal ReviewClaimCli::OK, code, "a claim exits 0"
      assert_equal "popped-task\n", @out.string, "stdout is JUST the slug for `slug=$(…)` capture"
      assert_equal "popped-task\n", File.read(marker(proj, "popped-task")),
                   "the held-review marker records the popped slug for release"
      assert_equal 1, @spawned.length, "the pop anchors a renewer just like acquire"
      _env, argv = @spawned.first
      assert_includes argv, "renew-loop"
      assert_includes argv, "popped-task"
      assert(c.instance_variable_get(:@api).posts.any? { |p| p[:path] == "/api/v1/tasks/claim_next_review" },
             "it POSTs the collection pop endpoint")
    end
  end

  def test_unit_claim_next_prints_none_and_exits_nonzero_when_nothing_eligible
    Dir.mktmpdir do |proj|
      c = cli(projects_dir: proj, data: { "claimed" => nil, "reason" => "no_green_ci" })
      code = c.run(["claim-next"])

      assert_equal ReviewClaimCli::NONE, code, "an empty pop exits nonzero (4), distinct from cant-run (1)"
      refute_equal 0, code
      assert_match(/^none$/, @out.string, "stdout says plainly there is nothing to review")
      assert_empty @spawned, "nothing claimed ⇒ no renewer"
      refute_path_exists marker(proj, "popped-task"), "no claim ⇒ no marker"
    end
  end

  def test_unit_claim_next_without_a_session_id_fails_open
    Dir.mktmpdir do |proj|
      code = cli(env: { "TASK_REVIEW_CLAIM_SESSION" => "" }, projects_dir: proj).run(["claim-next"])
      assert_equal ReviewClaimCli::CANT_RUN, code, "no session id → fail open (exit 1), never a false claim"
    end
  end
end
