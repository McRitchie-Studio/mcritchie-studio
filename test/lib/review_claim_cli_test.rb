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

  # The crew seat rides the CLAIM: acquire must SEND the reviewing soul, so the board
  # can paint the face the instant a review starts. Explicit --agent wins; otherwise
  # the session's sticky .acting-agent (what every narration call already attributes
  # to) supplies it, so a reviewer narrating as itself needs no extra flag.
  def test_unit_acquire_sends_the_explicit_reviewer_soul
    Dir.mktmpdir do |dir|
      c = cli(projects_dir: dir, data: { "acquired" => true })
      assert_equal 0, c.run(["acquire", SLUG, "--agent", "carl"])
      body = c.instance_variable_get(:@api).posts.last[:body]
      assert_equal "carl", body["reviewer"], "the claim carries the reviewing soul"
    end
  end

  def test_unit_acquire_falls_back_to_the_sessions_acting_agent
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".agents", "sessions"))
      File.write(File.join(dir, ".agents", "sessions", "#{SESSION}.acting-agent"), "shannon\n")

      c = cli(projects_dir: dir, data: { "acquired" => true })
      assert_equal 0, c.run(["acquire", SLUG])
      assert_equal "shannon", c.instance_variable_get(:@api).posts.last[:body]["reviewer"]
    end
  end

  def test_unit_acquire_without_any_soul_sends_a_blank_reviewer
    Dir.mktmpdir do |dir|
      c = cli(projects_dir: dir, data: { "acquired" => true })
      assert_equal 0, c.run(["acquire", SLUG])
      assert_equal "", c.instance_variable_get(:@api).posts.last[:body]["reviewer"],
                   "no soul resolved: claim the lane, paint no face (never guess a reviewer)"
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

  def test_acquire_refused_as_self_review_says_so_instead_of_naming_a_holder
    # A self_review refusal is NOT the held-by-another skip: nobody holds the
    # task, so the generic "already under review" line (with an empty holder)
    # would send the reviewer off to wait for a lease that will never lapse.
    Dir.mktmpdir do |proj|
      code = cli(projects_dir: proj,
                 data: { "acquired" => false, "disposition" => "self_review", "holder" => {} })
             .run(["acquire", SLUG])

      assert_equal ReviewClaimCli::SKIPPED, code
      assert_match(/YOU BUILT THIS/, @out.string, "the refusal names the actual reason")
      refute_match(/already under review/, @out.string, "it is not a race for a held lease")
      refute File.exist?(marker(proj)), "a refused claim writes no held-review marker"
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

  # THE WIRING WARNING is a failure-path ARTIFACT, so it is asserted like one. A
  # repo the board ingests no CI for reads exactly like a red queue in a bare
  # `no_green_ci`, which is how a 4/4-green mcritchie-industries PR sat unclaimed
  # for days. The reviewer must be told WHICH repo is blind and that wiring — not
  # a rebuild — is the fix.
  def test_unit_claim_next_names_a_blind_repo_on_an_empty_pop
    Dir.mktmpdir do |proj|
      c = cli(projects_dir: proj,
              data: { "claimed" => nil, "reason" => "no_green_ci",
                      "blind_repos" => ["mcritchie-industries"] })
      code = c.run(["claim-next"])

      assert_equal ReviewClaimCli::NONE, code, "a blind repo is still an empty pop, not an error"
      assert_match(/mcritchie-industries/, @err.string, "the blind repo is NAMED, not merely counted")
      assert_match(/WIRING gap/i, @err.string, "it says wiring, so nobody re-runs a build that was never seen")
    end
  end

  def test_unit_claim_next_stays_quiet_when_no_repo_is_blind
    Dir.mktmpdir do |proj|
      c = cli(projects_dir: proj, data: { "claimed" => nil, "reason" => "no_green_ci", "blind_repos" => [] })
      c.run(["claim-next"])

      refute_match(/WIRING gap/i, @err.string, "a red queue must not be dressed up as a wiring gap")
    end
  end

  def test_unit_claim_next_without_a_session_id_fails_open
    Dir.mktmpdir do |proj|
      code = cli(env: { "TASK_REVIEW_CLAIM_SESSION" => "" }, projects_dir: proj).run(["claim-next"])
      assert_equal ReviewClaimCli::CANT_RUN, code, "no session id → fail open (exit 1), never a false claim"
    end
  end

  # --- [unit] every argument is accounted for BEFORE anything is claimed ---------
  # THE SCAR: `bin/task claim-next-review --help` CLAIMED A REAL TASK. The flag fell
  # through parse_flags into an ignored key and the atomic pop ran anyway, taking a
  # live review lease on work nobody was reviewing. So the assertion here is never
  # "usage was printed" — printed text is compatible with the bug. It is that NO POP
  # REACHED THE BOARD: no request recorded, no marker, no renewer.
  #
  # `posts` is the whole seam: FakeApi records every http_json, so a claim that
  # happened is a claim that shows up here. The pop the tests above assert
  # (POST /api/v1/tasks/claim_next_review) must be ABSENT.
  def assert_claimed_nothing(cli, proj, message)
    assert_empty cli.instance_variable_get(:@api).posts, "#{message}: it reached the BOARD"
    assert_empty @spawned, "#{message}: it anchored a renewer"
    assert_empty @out.string, "#{message}: it printed a slug on stdout"
    refute_path_exists File.join(proj, ".agents", "sessions"), "#{message}: it wrote a claim marker"
  end

  def test_unit_claim_next_help_prints_usage_and_claims_nothing
    Dir.mktmpdir do |proj|
      c = cli(projects_dir: proj, data: { "claimed" => { "slug" => "popped-task" } })
      code = c.run(["claim-next", "--help"])

      # The claim assertion FIRST, deliberately: pre-fix, `--help` also exited 0 —
      # it exited 0 having CLAIMED. The exit code and the printed text are the two
      # things a regression would keep; the absent pop is the thing it breaks.
      assert_claimed_nothing(c, proj, "claim-next --help")
      assert_equal ReviewClaimCli::OK, code, "--help is a clean exit 0, like bin/task's own help"
      assert_match(/usage: bin\/task review-claim/, @err.string, "usage goes to STDERR, never stdout")
    end
  end

  # -h is the same probe with one dash — and the MORE dangerous spelling before this
  # guard: parse_flags only ever looked at "--", so a single-dash token was not even
  # recorded as an ignored key. It vanished, and the pop ran.
  def test_unit_claim_next_short_help_claims_nothing_either
    Dir.mktmpdir do |proj|
      c = cli(projects_dir: proj, data: { "claimed" => { "slug" => "popped-task" } })
      code = c.run(["claim-next", "-h"])

      assert_claimed_nothing(c, proj, "claim-next -h")
      assert_equal ReviewClaimCli::OK, code
      assert_match(/usage: bin\/task review-claim/, @err.string)
    end
  end

  def test_unit_claim_next_refuses_an_unknown_flag_instead_of_claiming
    Dir.mktmpdir do |proj|
      c = cli(projects_dir: proj, data: { "claimed" => { "slug" => "popped-task" } })
      code = c.run(["claim-next", "--fast"])

      assert_claimed_nothing(c, proj, "claim-next --fast")
      assert_equal ReviewClaimCli::CANT_RUN, code, "an unrecognized flag REFUSES (exit 1)"
      assert_match(/unrecognized argument "--fast"/, @err.string, "the refusal NAMES the offending flag")
      assert_match(/NOTHING was claimed/, @err.string, "and says plainly no lease was taken")
    end
  end

  # A slug on the claim-next line means the caller wanted `acquire`. Popping whatever
  # the board ranks first would claim a DIFFERENT task than the one they typed — the
  # same silently-discarded-argument defect, one seam over.
  def test_unit_claim_next_refuses_a_slug_it_would_have_ignored
    Dir.mktmpdir do |proj|
      c = cli(projects_dir: proj, data: { "claimed" => { "slug" => "popped-task" } })
      code = c.run(["claim-next", "some-other-task"])

      assert_claimed_nothing(c, proj, "claim-next <slug>")
      assert_equal ReviewClaimCli::CANT_RUN, code
      assert_match(/unrecognized argument "some-other-task"/, @err.string)
      assert_match(/review-claim acquire some-other-task/, @err.string,
                   "the refusal names the door they meant, not just the one that closed")
    end
  end

  # THE POSITIVE CONTROL. Without it a guard that refused EVERYTHING would read as a
  # working fix — and the failure mode is silent: a review wave that claims nothing
  # looks exactly like an empty queue. A valid line must still take the lease, and
  # its value-flags must still ARRIVE (--label Gastly must not be read as a stray
  # positional, which is precisely how a too-eager guard breaks this).
  def test_unit_claim_next_with_valid_flags_still_claims
    Dir.mktmpdir do |proj|
      c = cli(projects_dir: proj,
              data: { "claimed" => { "slug" => "popped-task" }, "holder" => { "label" => "Gastly" } })
      code = c.run(["claim-next", "--label", "Gastly", "--agent", "carl"])

      assert_equal ReviewClaimCli::OK, code, "a valid invocation still claims — the guard is not a wall"
      assert_equal "popped-task\n", @out.string, "stdout is still JUST the slug"
      pop = c.instance_variable_get(:@api).posts.find { |p| p[:path] == "/api/v1/tasks/claim_next_review" }
      refute_nil pop, "the atomic pop still reaches the board"
      assert_equal "Gastly", pop[:body]["label"], "--label's VALUE arrived, not refused as a positional"
      assert_equal "carl", pop[:body]["reviewer"], "--agent's VALUE arrived too"
      assert_equal 1, @spawned.length, "and the renewer is still anchored"
    end
  end

  # The same contract on the sibling that names its own task: `acquire <slug> --help`
  # must not acquire, and a typo'd flag must not either.
  def test_unit_acquire_help_after_the_slug_claims_nothing
    Dir.mktmpdir do |proj|
      c = cli(projects_dir: proj, data: { "acquired" => true, "holder" => {} })
      code = c.run(["acquire", SLUG, "--help"])

      assert_claimed_nothing(c, proj, "acquire <slug> --help")
      assert_equal ReviewClaimCli::OK, code
    end
  end

  def test_unit_acquire_refuses_an_unknown_flag_instead_of_acquiring
    Dir.mktmpdir do |proj|
      c = cli(projects_dir: proj, data: { "acquired" => true, "holder" => {} })
      code = c.run(["acquire", SLUG, "--soul", "carl"])

      assert_claimed_nothing(c, proj, "acquire --soul")
      assert_equal ReviewClaimCli::CANT_RUN, code
      assert_match(/unrecognized argument "--soul"/, @err.string)
      assert_match(/valid flags: --label, --agent/, @err.string, "the refusal names what IS valid")
    end
  end

  # A value-flag BEFORE the slug used to make the flag's VALUE the slug (`acquire
  # --label Gastly my-task` POSTed to /api/v1/tasks/Gastly/review_claim). The slug is
  # now the first true POSITIONAL, so the same line claims the task the caller named.
  def test_unit_acquire_reads_the_slug_past_a_value_flag
    Dir.mktmpdir do |proj|
      c = cli(projects_dir: proj, data: { "acquired" => true, "holder" => {} })
      code = c.run(["acquire", "--label", "Gastly", SLUG])

      assert_equal ReviewClaimCli::OK, code
      post = c.instance_variable_get(:@api).posts.first
      assert_equal "/api/v1/tasks/#{SLUG}/review_claim", post[:path], "the SLUG is the target, not the label"
    end
  end

  # The renewer is spawned by the CLI and re-enters the CLI. A guard that refused its
  # argv would kill every lease renewal silently — the claim would lapse mid-review
  # and a second session could claim the same task. Pin the real spawned line against
  # the real validator instead of a hand-copied argv that could drift.
  def test_unit_the_renewers_own_argv_survives_the_argument_guard
    Dir.mktmpdir do |proj|
      c = cli(projects_dir: proj, data: { "acquired" => true, "holder" => {} })
      c.run(["acquire", SLUG])

      _env, argv = @spawned.first
      spawned_args = argv.drop(2) # [ruby, review_claim_cli.rb, "renew-loop", slug, …flags]
      assert_equal "renew-loop", spawned_args.first
      assert_empty c.bad_arguments(spawned_args.first, spawned_args.drop(1)),
                   "the renewer's own line must not be refused by the guard it re-enters"
    end
  end

  # COMMAND_FLAGS is the dictionary the guard rejects against AND the set of
  # subcommands run() accepts, so a command added to one and not the other silently
  # becomes "unknown subcommand". Pin them together.
  def test_unit_every_validated_command_has_a_dispatch_arm
    source = File.read(File.expand_path("../../bin/lib/review_claim_cli.rb", __dir__))
    ReviewClaimCli::COMMAND_FLAGS.each_key do |command|
      assert_includes source, "when \"#{command}\"",
                      "#{command} is validated but never dispatched — it would print usage instead of running"
    end
  end

  def test_unit_an_unknown_subcommand_still_prints_usage_and_claims_nothing
    Dir.mktmpdir do |proj|
      c = cli(projects_dir: proj, data: { "claimed" => { "slug" => "popped-task" } })
      code = c.run(["claim-everything"])

      assert_claimed_nothing(c, proj, "an unknown subcommand")
      assert_equal ReviewClaimCli::CANT_RUN, code
      assert_match(/usage: bin\/task review-claim/, @err.string)
    end
  end
end
