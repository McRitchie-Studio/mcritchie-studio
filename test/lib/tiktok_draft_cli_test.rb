# frozen_string_literal: true

require "minitest/autorun"
require "stringio"
require_relative "../../bin/lib/tiktok_draft_cli"

# [unit] The agent side of the tiktok-draft SOP (bin/tiktok-draft) with the hub
# API faked: a dry run only reads; a draft reads the preview, records one
# attempt and waits for it to settle; a refusal or a server without keys stops
# before the POST; --status refreshes only what is still processing.
class TiktokDraftCliTest < Minitest::Test
  SLUG = "test-artist-a-tiled-demo-alt-1-clip-01"
  INDEX = "/api/v1/alt_video_clips/#{SLUG}/tiktok_drafts".freeze
  PREVIEW = { "version_number" => 1, "athlete" => "Test Tiktok Alpha", "look" => "Home", "athlete_rule" => "the clip's target",
              "team" => "Buffalo Bills", "team_from" => "look", "caption" => "Bills 3-2 #nfl #nfltiktok #footballtiktok #bills #fyp",
              "caption_length" => 53, "facts" => { "record" => "3-2", "source" => "ESPN (synthetic)", "read_at" => "2026-10-07T12:00:00Z" },
              "exceptions" => ["Buffalo Bills has no slogan hashtag on file"] }.freeze

  def self.attempt(id, state, **extra)
    { "id" => id, "version_number" => 1, "state" => state, "state_label" => state.capitalize, "byte_size" => 2_048 }.merge(extra.transform_keys(&:to_s))
  end

  class FakeApi
    attr_reader :calls

    def initialize(preview: PREVIEW, available: true, states: %w[uploading delivered], attempts: [])
      @preview = preview
      @available = available
      @states = states.dup
      @attempts = attempts
      @calls = []
    end

    def get(path)
      @calls << [:get, path]
      return { "creator_username" => "synthetic_show", "creator_nickname" => "Synthetic Show" } if path.end_with?("creator_info")

      if @posted
        state = @states.size > 1 ? @states.shift : @states.first
        @attempts = [TiktokDraftCliTest.attempt(7, state, publish_id: "p7", error: state == "failed" ? "TikTok refused chunk 1" : nil)]
      end
      { "clip" => { "slug" => SLUG, "name" => "Clip 1", "alt_video" => "test-artist-a-tiled-demo-alt-1", "primary_version" => 1,
                    "available" => @available, "stand_in" => false },
        "preview" => @preview, "attempts" => @attempts }
    end

    def post(path, payload)
      @calls << [:post, path, payload]
      return TiktokDraftCliTest.attempt(path[%r{/(\d+)/refresh}, 1].to_i, "delivered", tiktok_status: "SEND_TO_USER_INBOX") if path.end_with?("/refresh")

      @posted = true
      TiktokDraftCliTest.attempt(7, "queued")
    end
  end

  # admin_api: the client carrying the admin session's token. By default the
  # same fake, so one call list shows every request in order.
  def runner(api, out = StringIO.new, admin_api: api)
    clock = Time.at(0)
    [TiktokDraftCli::Runner.new(api:, admin_api:, out:, wait: 60, sleeper: ->(s) { clock += s }, clock: -> { clock }), out]
  end

  def test_a_dry_run_prints_the_caption_and_posts_nothing
    api = FakeApi.new
    run, out = runner(api)
    run.dry_run(SLUG)

    assert_equal [[:get, INDEX]], api.calls
    assert_includes out.string, "Bills 3-2 #nfl #nfltiktok #footballtiktok #bills #fyp"
    assert_includes out.string, "CHECK: Buffalo Bills has no slogan hashtag on file"
    assert_includes out.string, "athlete: Test Tiktok Alpha (Home), the clip's target"
    assert_includes out.string, "dry run: nothing was recorded"
  end

  def test_a_draft_records_one_attempt_and_waits_for_it_to_settle
    api = FakeApi.new
    run, out = runner(api)
    attempt = run.draft(SLUG)

    assert_equal "delivered", attempt["state"]
    assert_equal 1, api.calls.count { |c| c.first == :post }
    assert_equal [:post, INDEX, { requested_by: "bin/tiktok-draft" }], api.calls.find { |c| c.first == :post }
    assert_includes out.string, "attempt 7: Version 1 · Delivered · publish_id p7"
  end

  def test_a_refused_clip_stops_before_the_post
    api = FakeApi.new(preview: { "refused" => "Clip 1 has no generated version yet" })
    run, = runner(api)

    error = assert_raises(TiktokDraftCli::Failure) { run.draft(SLUG) }
    assert_match(/cannot be drafted: Clip 1 has no generated version yet/, error.message)
    assert(api.calls.none? { |c| c.first == :post })
  end

  def test_a_server_without_keys_stops_before_the_post
    api = FakeApi.new(available: false)
    run, = runner(api)

    error = assert_raises(TiktokDraftCli::Failure) { run.draft(SLUG) }
    assert_match(/TikTok keys are not set/, error.message)
    assert(api.calls.none? { |c| c.first == :post })
  end

  def test_a_failed_attempt_is_a_failure_with_tiktoks_words
    run, = runner(FakeApi.new(states: %w[failed]))

    error = assert_raises(TiktokDraftCli::Failure) { run.draft(SLUG) }
    assert_match(/attempt 7 failed: TikTok refused chunk 1/, error.message)
  end

  def test_an_attempt_still_processing_at_the_deadline_is_reported_not_failed
    run, out = runner(FakeApi.new(states: %w[processing]))
    attempt = run.draft(SLUG)

    assert_equal "processing", attempt["state"]
    assert_includes out.string, "still processing after 60s"
  end

  def test_status_refreshes_only_what_is_still_processing
    api = FakeApi.new(attempts: [self.class.attempt(3, "failed", error: "x"), self.class.attempt(4, "processing")])
    run, out = runner(api)
    run.status(SLUG)

    assert_equal [[:post, "/api/v1/tiktok_drafts/4/refresh", {}]], api.calls.select { |c| c.first == :post }
    assert_includes out.string, "attempt 4: Version 1 · Delivered · TikTok SEND_TO_USER_INBOX"
  end

  def test_whoami_prints_the_account
    run, out = runner(FakeApi.new)
    run.whoami

    assert_includes out.string, "TikTok account: @synthetic_show (Synthetic Show)"
  end

  # ── Hardening (piece 22) ─────────────────────────────────────────────────────

  def test_a_draft_without_an_admin_session_stops_before_any_request_and_says_how_to_get_one
    api = FakeApi.new
    run, = runner(api, admin_api: nil)

    error = assert_raises(TiktokDraftCli::Failure) { run.draft(SLUG) }
    assert_match(/needs an admin session/, error.message)
    assert_match(/AGENT_ADMIN_SESSION_TOKEN/, error.message)
    assert_match(/agent_sessions:grant_admin/, error.message)
    assert_empty api.calls
  end

  def test_the_draft_is_posted_with_the_admin_session_and_everything_else_with_the_shared_token
    api = FakeApi.new
    admin = FakeApi.new
    api.define_singleton_method(:post) { |*| raise "the draft must go out on the admin session" }
    admin.define_singleton_method(:get) { |*| raise "reads stay on the shared token" }
    admin.define_singleton_method(:post) do |path, payload|
      calls << [:post, path, payload]
      api.instance_variable_set(:@posted, true)
      TiktokDraftCliTest.attempt(7, "queued")
    end
    run, = runner(api, admin_api: admin)

    assert_equal "delivered", run.draft(SLUG)["state"]
    assert_equal [[:post, INDEX, { requested_by: "bin/tiktok-draft" }]], admin.calls
  end

  def test_a_dry_run_a_status_and_the_probe_need_no_admin_session
    run, = runner(FakeApi.new(attempts: [self.class.attempt(4, "processing")]), admin_api: nil)

    assert run.dry_run(SLUG)
    assert run.status(SLUG)
    assert run.whoami
  end

  def test_a_refused_admin_session_says_how_to_get_a_fresh_one
    api = FakeApi.new
    admin = Object.new
    admin.define_singleton_method(:post) { |*| raise DigestVideo::Failure, "API 401: SESSION_ENDED agent session sess-1 expired at 2026-10-07T00:00:00Z" }
    run, = runner(api, admin_api: admin)

    error = assert_raises(TiktokDraftCli::Failure) { run.draft(SLUG) }
    assert_match(/SESSION_ENDED agent session sess-1 expired/, error.message)
    assert_match(/agent_sessions:grant_admin/, error.message)
  end

  def test_an_upload_with_its_status_unknown_is_reported_not_failed_and_points_at_the_phone
    states = %w[unknown]
    api = FakeApi.new(states:)
    api.define_singleton_method(:get) do |path|
      data = super(path)
      data["attempts"].each { |a| a["error"] = "The upload reached TikTok, but its status could not be read (EOFError). Check your TikTok drafts." if a["state"] == "unknown" }
      data
    end
    run, out = runner(api)
    attempt = run.draft(SLUG)

    assert_equal "unknown", attempt["state"]
    assert_includes out.string, "Check your TikTok drafts"
    assert_includes out.string, "do not draft it again"
    assert_includes out.string, "--status"
  end

  def test_status_also_re_reads_an_attempt_whose_status_is_unknown
    api = FakeApi.new(attempts: [self.class.attempt(3, "failed", error: "x"), self.class.attempt(5, "unknown")])
    run, = runner(api)
    run.status(SLUG)

    assert_equal [[:post, "/api/v1/tiktok_drafts/5/refresh", {}]], api.calls.select { |c| c.first == :post }
  end

  # --yes guards every hub that is not this machine: --production, and --api
  # pointed at one (the door the flag used to leave open).
  def test_a_draft_on_any_hub_but_this_machine_needs_yes
    remote = ["https://mcritchie.studio", "https://mcritchie.studio/", "http://mcritchie.studio:80", "https://studio.example.com",
              "https://localhost.evil.example", "http://10.0.0.5:3000", "not a url", ""]
    local = ["http://localhost:3000", "http://127.0.0.1:3038", "http://localhost:3038/", "http://[::1]:3000"]

    remote.each { |url| refute TiktokDraftCli.local_hub?(url), "#{url.inspect} is not this machine" }
    local.each { |url| assert TiktokDraftCli.local_hub?(url), "#{url.inspect} is this machine" }

    remote.first(3).each do |url|
      assert_match(/lands on Alex's phone/, TiktokDraftCli.yes_refusal(base_url: url, yes: false))
      assert_nil TiktokDraftCli.yes_refusal(base_url: url, yes: true)
    end
    assert_nil TiktokDraftCli.yes_refusal(base_url: "http://localhost:3000", yes: false)
  end

  def test_the_bin_refuses_a_production_url_given_as_api_without_yes
    out = `#{File.expand_path("../../bin/tiktok-draft", __dir__)} #{SLUG} --api https://hub.invalid 2>&1` # .invalid never resolves: no request can leave

    refute $?.success?
    assert_match(/lands on Alex's phone/, out)
  end

  def test_the_admin_token_is_picked_out_of_whatever_the_grant_printed_around_it
    token = "eyJfcmFpbHMiOnsiZGF0YSI6eyJzaWQiOiJzZXNzLXN5bnRoZXRpYyJ9fX0=--#{'ab12' * 16}"
    noisy = "DEPRECATION WARNING: synthetic\nadmin session sess-synthetic granted to xan (admin), ends 2026-10-08T06:00:00Z.\n#{token}\r\n"

    assert_equal token, TiktokDraftCli.admin_token(token)
    assert_equal token, TiktokDraftCli.admin_token(noisy)
    assert_equal token, TiktokDraftCli.admin_token("#{token}\nadmin session sess-synthetic granted to xan")
    [nil, "", "   ", "not a token", "Running bin/rails on mcritchie-studio... up, run.1234"].each do |raw|
      assert_nil TiktokDraftCli.admin_token(raw), "#{raw.inspect} holds no token"
    end
  end

  # The board's grant: the admin login the harness session collected is presented
  # to the board that granted it, and to no other hub.
  def test_the_held_admin_login_is_presented_only_to_the_board_that_granted_it
    require "tmpdir"
    Dir.mktmpdir do |proj|
      env = { "CLAUDE_PROJECTS_DIR" => proj, "CLAUDE_CODE_SESSION_ID" => "harness-tiktok" }
      assert_nil TiktokDraftCli.held_admin_token(base_url: "https://mcritchie.studio", env: env), "no login held"

      AdminLogin.write("harness-tiktok", proj, { "soul" => "xan", "session" => "sess-admin", "token" => "ADMIN-TOKEN",
                                                 "expires_at" => (Time.now + 3600).utc.iso8601 }, env: env)
      assert_equal "ADMIN-TOKEN", TiktokDraftCli.held_admin_token(base_url: "https://mcritchie.studio", env: env)
      assert_equal "ADMIN-TOKEN", TiktokDraftCli.held_admin_token(base_url: "http://localhost:3000",
                                                                  env: env.merge("ATOMIC_CAPTURE_URL" => "http://localhost:3000"))
      ["http://localhost:3000", "https://hub.invalid", "not a url"].each do |other|
        assert_nil TiktokDraftCli.held_admin_token(base_url: other, env: env), "#{other} did not grant this login"
      end
      assert_nil TiktokDraftCli.held_admin_token(base_url: "https://mcritchie.studio",
                                                 env: env.merge("CLAUDE_CODE_SESSION_ID" => "another-harness"))
    end
  end

  def test_the_bin_without_an_admin_session_says_how_and_sends_nothing
    out = `env -u AGENT_ADMIN_SESSION_TOKEN #{File.expand_path("../../bin/tiktok-draft", __dir__)} #{SLUG} --api https://hub.invalid --yes 2>&1`

    refute $?.success?
    assert_match(/AGENT_ADMIN_SESSION_TOKEN is not set/, out)
    assert_match(/bin\/agent-activity heartbeat xan/, out, "the board's grant is named first")
    assert_match(/agent_sessions:grant_admin/, out)
    assert_operator out.index("heartbeat xan"), :<, out.index("agent_sessions:grant_admin")
  end
end
