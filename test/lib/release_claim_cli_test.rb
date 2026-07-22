# frozen_string_literal: true

# [unit] tests for the release-conductor-claim CLI (ReleaseClaimCli). The board
# behavior is covered by
# test/controllers/api/v1/release_conductor_claims_controller_test.rb; here we pin the
# CLI's own logic: exit-code branching on the acquire verdict (0 held / 10 stood down /
# 1 fail-open), the held-claim marker, the detached renewer + the identity it carries,
# and the graceful no-session/no-slug/no-role fallbacks — with a fake API so no server
# is needed.
#
#   ruby -Itest test/lib/release_claim_cli_test.rb

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

load File.expand_path("../../bin/lib/release_claim_cli.rb", __dir__)

class ReleaseClaimCliTest < Minitest::Test
  SESSION = "7cc218a6-8676-4cf5-ce12-81804d9cb728"
  SLUG = "rel-20260721-abc123"
  FORMING = "__forming__" # the fresh-create assembly sentinel (ReleaseConductorClaim::FORMING_SLUG)

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
    # the claim marker writes there instead of the operator's real ~/projects/.agents.
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
    c = ReleaseClaimCli.new(env: { "RELEASE_CONDUCTOR_CLAIM_SESSION" => SESSION,
                                   "RELEASE_CONDUCTOR_CLAIM_ANCHOR_PID" => Process.pid.to_s }.merge(env),
                            out: (@out = StringIO.new), err: (@err = StringIO.new))
    c.instance_variable_set(:@api, FakeApi.new(projects_dir: projects_dir, data: data, code: code))
    @spawned = []
    c.instance_variable_set(:@spawner, ->(spawn_env, argv) { @spawned << [spawn_env, argv]; 4242 })
    c
  end

  # Markers are keyed per (session, ROLE, SLUG) — the slug is in the suffix so the
  # forming sentinel and the real assembler claim (same role, different slug) never
  # share a renewer-pid marker.
  def marker(projects_dir, role = "assembler", slug = SLUG)
    File.join(projects_dir, ".agents", "sessions", "#{SESSION}.release-conductor-claim-#{role}-#{slug}")
  end

  def renewer_marker(projects_dir, role, slug = SLUG)
    File.join(projects_dir, ".agents", "sessions", "#{SESSION}.release-conductor-claim-renewer-#{role}-#{slug}")
  end

  # Drift guard: the standalone bin/release CLI reads the forming sentinel from
  # ReleaseClaimCli::FORMING_SLUG (it can't load the AR model), so it MUST equal the
  # literal the model pins. If these two drift, the fresh-create hand-off releases the
  # wrong row.
  def test_forming_slug_constant_matches_the_reserved_sentinel_literal
    assert_equal "__forming__", ReleaseClaimCli::FORMING_SLUG
    assert_equal FORMING, ReleaseClaimCli::FORMING_SLUG
  end

  def test_acquire_success_exits_zero_and_writes_the_marker
    Dir.mktmpdir do |proj|
      code = cli(projects_dir: proj, data: { "acquired" => true, "holder" => { "label" => "Snorlax" } })
             .run(["acquire", SLUG, "--role", "assembler"])
      assert_equal ReleaseClaimCli::OK, code
      assert_match(/assembler claimed/, @out.string)
      assert_equal "#{SLUG}\n", File.read(marker(proj)), "the held-claim marker records the slug for release"
    end
  end

  def test_acquire_targets_the_conductor_claim_endpoint_with_the_role_in_the_body
    Dir.mktmpdir do |proj|
      c = cli(projects_dir: proj, data: { "acquired" => true, "holder" => {} })
      c.run(["acquire", SLUG, "--role", "deployer"])
      post = c.instance_variable_get(:@api).posts.find { |p| p[:path] == "/api/v1/releases/#{SLUG}/conductor_claim" }
      refute_nil post, "acquire posts to the release's conductor_claim endpoint"
      assert_equal "deployer", post[:body]["role"], "the role travels in the body"
      assert_equal SESSION, post[:body]["session"]
    end
  end

  # An UNPINNED caller must fail closed — the .release-conductor-claim marker lives in
  # the same store as .devops-shift/.task-review-claim. This asserts a caller which
  # FORGETS to pin aborts instead of writing the operator's live narration store.
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
          c.run(["acquire", SLUG, "--role", "assembler"])
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
                         "holder" => { "label" => "Snorlax", "session" => "sess-A", "heartbeat_age" => 3 } })
             .run(["acquire", SLUG, "--role", "deployer"])
      assert_equal ReleaseClaimCli::STOOD_DOWN, code, "a held release makes the second session stand down (exit 10)"
      assert_match(/STAND DOWN/, @out.string)
      assert_match(/Snorlax/, @out.string, "the stand-down message names the live holder")
      refute File.exist?(marker(proj, "deployer")), "a stood-down session must NOT write a held-claim marker"
    end
  end

  def test_acquire_without_a_session_id_fails_open_not_wedged
    Dir.mktmpdir do |proj|
      code = cli(env: { "RELEASE_CONDUCTOR_CLAIM_SESSION" => "" }, projects_dir: proj)
             .run(["acquire", SLUG, "--role", "assembler"])
      assert_equal ReleaseClaimCli::CANT_RUN, code, "no session id → fail open (exit 1), never a false claim"
    end
  end

  def test_acquire_without_a_slug_is_a_usage_error
    Dir.mktmpdir do |proj|
      assert_equal ReleaseClaimCli::CANT_RUN, cli(projects_dir: proj).run(%w[acquire --role assembler])
      assert_match(/needs a release slug/, @err.string)
    end
  end

  def test_acquire_without_a_role_is_a_usage_error
    Dir.mktmpdir do |proj|
      assert_equal ReleaseClaimCli::CANT_RUN, cli(projects_dir: proj).run(["acquire", SLUG])
      assert_match(/needs --role/, @err.string)
    end
  end

  def test_acquire_with_an_unknown_role_is_a_usage_error
    Dir.mktmpdir do |proj|
      assert_equal ReleaseClaimCli::CANT_RUN, cli(projects_dir: proj).run(["acquire", SLUG, "--role", "wrangler"]),
                   "an unknown role is a usage error, NOT fail-open — renewing the wrong role's claim no-ops silently"
      assert_match(/needs --role/, @err.string)
    end
  end

  def test_release_clears_the_marker_and_posts_release
    Dir.mktmpdir do |proj|
      FileUtils.mkdir_p(File.dirname(marker(proj)))
      File.write(marker(proj), "#{SLUG}\n")
      c = cli(projects_dir: proj, data: { "released" => true })
      assert_equal ReleaseClaimCli::OK, c.run(["release", SLUG, "--role", "assembler"])
      refute File.exist?(marker(proj)), "release clears the held-claim marker"
      assert(c.instance_variable_get(:@api).posts.any? do |p|
        p[:path] == "/api/v1/releases/#{SLUG}/conductor_claim/release"
      end)
    end
  end

  # --- [unit] acquire must arrange its OWN renewal ------------------------------
  # A headless prepare/ship paints no status line, so the ONLY thing keeping its claim
  # alive is a renewer tied to the run itself. Acquire starts one.
  def test_unit_acquire_starts_a_renewer_so_a_headless_conductor_keeps_the_release
    Dir.mktmpdir do |proj|
      c = cli(projects_dir: proj, data: { "acquired" => true, "holder" => {} })
      assert_equal ReleaseClaimCli::OK, c.run(["acquire", SLUG, "--role", "deployer"])

      assert_equal 1, @spawned.length,
                   "acquire must start its own renewer — the status line is not always there"
      _spawn_env, argv = @spawned.first
      assert_includes argv, "renew-loop", "the child runs the renewer command"
      assert_includes argv, SLUG, "for the release it just claimed"
      assert_includes argv, "deployer", "and carries the role it holds"
      assert_includes argv, "--anchor-pid", "and is anchored to a process it can probe for liveness"
    end
  end

  # The renewer runs DETACHED, so it cannot re-derive the live-instance identity by
  # walking its own ancestry. If it guessed, `renew` would silently 204 forever and the
  # lease would lapse. So identity is handed down explicitly — the WRONG nonce is the
  # exact silent failure this asserts against.
  def test_unit_the_renewer_inherits_the_live_instance_identity_explicitly
    Dir.mktmpdir do |proj|
      c = cli(projects_dir: proj, env: { "TASK_CLAIM_NONCE" => "inst-A" },
              data: { "acquired" => true, "holder" => {} })
      c.run(["acquire", SLUG, "--role", "assembler"])

      spawn_env, = @spawned.first
      assert_equal SESSION, spawn_env["RELEASE_CONDUCTOR_CLAIM_SESSION"], "same session id as the conductor"
      assert_equal "inst-A", spawn_env["TASK_CLAIM_NONCE"],
                   "same nonce — a renewer with a different nonce renews NOTHING and no-ops silently"
    end
  end

  def test_unit_a_stood_down_session_never_starts_a_renewer
    Dir.mktmpdir do |proj|
      c = cli(projects_dir: proj, data: { "acquired" => false, "holder" => { "label" => "Snorlax" } })
      assert_equal ReleaseClaimCli::STOOD_DOWN, c.run(["acquire", SLUG, "--role", "assembler"])
      assert_empty @spawned, "you cannot renew a claim you were refused"
    end
  end

  def test_unit_release_that_the_board_refused_must_not_claim_success
    Dir.mktmpdir do |proj|
      c = cli(projects_dir: proj, code: 204, data: {})
      assert_equal ReleaseClaimCli::OK, c.run(["release", SLUG, "--role", "assembler"]),
                   "release is still never a hard failure"
      refute_match(/claim released\./, @out.string,
                   "a 204 means NOTHING was released — saying otherwise is a lie status would contradict")
      assert_match(/not held by this session/i, @out.string, "and it says so plainly")
    end
  end

  def test_unit_release_that_the_board_honored_reports_success
    Dir.mktmpdir do |proj|
      c = cli(projects_dir: proj, code: 200, data: { "released" => true })
      assert_equal ReleaseClaimCli::OK, c.run(["release", SLUG, "--role", "deployer"])
      assert_match(/claim released\./, @out.string)
    end
  end

  def test_unit_release_stops_the_renewer_it_started
    Dir.mktmpdir do |proj|
      acquirer = cli(projects_dir: proj, data: { "acquired" => true, "holder" => {} })
      acquirer.run(["acquire", SLUG, "--role", "deployer"])

      killed = []
      releaser = cli(projects_dir: proj, code: 200, data: { "released" => true })
      releaser.instance_variable_set(:@killer, ->(pid) { killed << pid })
      releaser.run(["release", SLUG, "--role", "deployer"])

      assert_equal [4242], killed, "the renewer must not outlive the claim it was renewing"
    end
  end

  # The two roles a conductor could hold are tracked independently: releasing the
  # assembler's renewer must never TERM the deployer's (they key on role). This is the
  # release analogue of the review claim's per-slug renewer independence.
  def test_unit_roles_track_renewers_independently
    Dir.mktmpdir do |proj|
      a = cli(projects_dir: proj, data: { "acquired" => true, "holder" => {} })
      a.instance_variable_set(:@spawner, ->(_env, _argv) { 111 })
      a.run(["acquire", SLUG, "--role", "assembler"])

      b = cli(projects_dir: proj, data: { "acquired" => true, "holder" => {} })
      b.instance_variable_set(:@spawner, ->(_env, _argv) { 222 })
      b.run(["acquire", SLUG, "--role", "deployer"])

      assert_path_exists renewer_marker(proj, "assembler"), "the assembler renewer is tracked"
      assert_path_exists renewer_marker(proj, "deployer"), "the deployer renewer is tracked separately"

      killed = []
      releaser = cli(projects_dir: proj, code: 200, data: { "released" => true })
      releaser.instance_variable_set(:@killer, ->(pid) { killed << pid })
      releaser.run(["release", SLUG, "--role", "assembler"])

      assert_equal [111], killed, "releasing assembler kills ONLY the assembler renewer, never the deployer's"
      refute_path_exists renewer_marker(proj, "assembler"), "the assembler renewer marker is cleared"
      assert_path_exists renewer_marker(proj, "deployer"), "the deployer renewer survives the assembler release"
    end
  end

  # GAP 1 (marker collision): the fresh-create hand-off holds the FORMING sentinel and
  # the real assembler claim AT ONCE (same role, different slug). A role-ONLY marker key
  # would make releasing the sentinel read the REAL claim's renewer pid and TERM it —
  # the real claim would lapse mid-assembly. Keying markers per (role, slug) keeps them
  # independent: the hand-off release kills only the sentinel's renewer.
  def test_unit_sentinel_and_real_assembler_claims_track_renewers_independently
    Dir.mktmpdir do |proj|
      sentinel = cli(projects_dir: proj, data: { "acquired" => true, "holder" => {} })
      sentinel.instance_variable_set(:@spawner, ->(_env, _argv) { 111 })
      sentinel.run(["acquire", FORMING, "--role", "assembler"])

      real = cli(projects_dir: proj, data: { "acquired" => true, "holder" => {} })
      real.instance_variable_set(:@spawner, ->(_env, _argv) { 222 })
      real.run(["acquire", SLUG, "--role", "assembler"])

      assert_path_exists renewer_marker(proj, "assembler", FORMING), "the sentinel renewer is tracked"
      assert_path_exists renewer_marker(proj, "assembler", SLUG), "the real assembler renewer is tracked separately"

      killed = []
      releaser = cli(projects_dir: proj, code: 200, data: { "released" => true })
      releaser.instance_variable_set(:@killer, ->(pid) { killed << pid })
      releaser.run(["release", FORMING, "--role", "assembler"]) # the hand-off

      assert_equal [111], killed, "the hand-off release kills ONLY the sentinel renewer, never the real claim's"
      refute_path_exists renewer_marker(proj, "assembler", FORMING), "sentinel renewer marker cleared"
      assert_path_exists renewer_marker(proj, "assembler", SLUG),
                         "the REAL assembler renewer survives the sentinel hand-off — assembly stays guarded"
    end
  end

  def test_renew_is_always_a_clean_exit_zero
    Dir.mktmpdir do |proj|
      assert_equal ReleaseClaimCli::OK,
                   cli(projects_dir: proj, data: { "renewed" => true }).run(["renew", SLUG, "--role", "assembler"])
    end
  end

  def test_parse_flags_reads_role_and_label_values
    Dir.mktmpdir do |proj|
      flags = cli(projects_dir: proj).parse_flags(%w[--role deployer --label Machamp])
      assert_equal "deployer", flags["role"]
      assert_equal "Machamp", flags["label"]
    end
  end
end
