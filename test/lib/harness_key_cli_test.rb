# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "stringio"
require "json"
require_relative "../../bin/lib/harness_key"
load File.expand_path("../../bin/harness-key", __dir__)

# [unit] The machine's harness key store and its CLI: the key is kept owner-only,
# never printed, and a sandboxed process never reads the operator's real one.
class HarnessKeyCliTest < Minitest::Test
  Resp = Struct.new(:code, :body)

  # A stand-in board: canned answers per path suffix, every call recorded.
  class FakeApi
    attr_reader :calls, :projects_dir

    def initialize(projects_dir, answers = {})
      @projects_dir = projects_dir
      @answers = answers
      @calls = []
    end

    def base_url = "https://board.test"
    def token = "shared-token"
    def env = { "CLAUDE_PROJECTS_DIR" => @projects_dir }

    def http_json(method, path, body, bearer:)
      @calls << { method: method, path: path, body: body, bearer: bearer }
      code, data = @answers.fetch(@answers.keys.find { |k| path.end_with?(k) }) { [404, { "error" => "not found" }] }
      data = data.shift if data.is_a?(Array) && data.first.is_a?(Array)
      code, data = data if code.nil?
      Resp.new(code.to_s, JSON.generate(code.to_i < 300 ? { "data" => data } : data))
    end

    def http_get(path, bearer:) = http_json(:get, path, nil, bearer: bearer)
  end

  def run_cli(proj, argv, answers = {})
    @api = FakeApi.new(proj, answers)
    @out = StringIO.new
    @err = StringIO.new
    HarnessKeyCli.new(argv, env: { "CLAUDE_PROJECTS_DIR" => proj, "CLAUDE_CODE_SESSION_ID" => "harness-1" },
                            out: @out, err: @err, api: @api, sleeper: ->(_) {}).run
  end

  def pin(proj) = { "CLAUDE_PROJECTS_DIR" => proj }

  def test_unit_the_key_file_is_owner_only_and_under_dot_agents
    Dir.mktmpdir do |proj|
      file = HarnessKey.write(proj, { "slug" => "sess-key", "token" => "KEY" }, env: pin(proj))

      assert_equal File.join(proj, ".agents", "harness-key.json"), file
      assert_equal 0o600, File.stat(file).mode & 0o777
      assert_equal "KEY", HarnessKey.token(proj, env: pin(proj))
    end
  end

  def test_unit_a_machine_with_no_file_or_a_pending_request_holds_no_key
    Dir.mktmpdir do |proj|
      assert_nil HarnessKey.token(proj, env: pin(proj))

      HarnessKey.write(proj, { "request" => "login-1", "collect_key" => "ck", "ends_at" => (Time.now + 60).utc.iso8601 }, env: pin(proj))
      assert_nil HarnessKey.token(proj, env: pin(proj))
      assert_equal "login-1", HarnessKey.open_request(proj, env: pin(proj))["request"]
      assert_nil HarnessKey.open_request(proj, now: Time.now + 120, env: pin(proj)), "a lapsed request is not open"
    end
  end

  def test_unit_a_sandboxed_process_never_reads_the_operators_real_key
    Dir.mktmpdir do |real|
      HarnessKey.write(real, { "slug" => "sess-key", "token" => "REAL-KEY" }, env: pin(real))

      # Armed and unpinned: the read answers nothing.
      assert_nil HarnessKey.token(real, env: { TaskUsageSandbox::ENV_KEY => "1" })
      # Control: the same file, with no sandbox armed, is read.
      assert_equal "REAL-KEY", HarnessKey.token(real, env: { TaskUsageSandbox::ENV_KEY => "0" })
    end
  end

  def test_unit_a_mint_presents_the_key_and_falls_back_only_on_401_or_silence
    seen = []
    ask = ->(answers) { ->(bearer) { seen << bearer; answers.shift } }
    refusals = []

    assert_equal "201", HarnessKey.mint("KEY", fallback: -> { flunk("no fallback on a mint") }, &ask.call([Resp.new("201", "")])).code
    # A 403 is the board's answer about the login (an entitlement refusal), not about the key.
    assert_equal "403", HarnessKey.mint("KEY", fallback: -> { flunk("no fallback on 403") }, &ask.call([Resp.new("403", "")])).code
    assert_equal %w[KEY KEY], seen

    seen.clear
    res = HarnessKey.mint("KEY", fallback: -> { "SHARED" }, refused: ->(r) { refusals << r.code },
                          &ask.call([Resp.new("401", ""), Resp.new("201", "")]))
    assert_equal ["201", %w[KEY SHARED], ["401"]], [res.code, seen, refusals]

    seen.clear
    assert_equal "201", HarnessKey.mint(nil, fallback: -> { "SHARED" }, &ask.call([Resp.new("201", "")])).code
    assert_equal %w[SHARED], seen
  end

  def test_unit_request_posts_a_harness_key_request_with_the_shared_token_and_prints_the_slug_only
    Dir.mktmpdir do |proj|
      code = run_cli(proj, ["request", "--label", "studio-mac"],
                     "/agent_login_requests" => [201, { "slug" => "login-abc", "collect_key" => "COLLECT-KEY",
                                                        "ends_at" => (Time.now + 600).utc.iso8601 }])

      assert_equal HarnessKeyCli::OK, code
      call = @api.calls.first
      assert_equal ["shared-token", "harness_key", "studio-mac", "harness-1"],
                   [call[:bearer], *call[:body].values_at("kind", "label", "harness_session_id")]
      assert_includes @out.string, "login-abc requested for studio-mac"
      refute_includes @out.string + @err.string, "COLLECT-KEY"
      assert_equal "COLLECT-KEY", HarnessKey.open_request(proj, env: pin(proj))["collect_key"]
    end
  end

  def test_unit_collect_with_the_code_keeps_the_key_and_prints_its_length_only
    Dir.mktmpdir do |proj|
      HarnessKey.write(proj, { "request" => "login-abc", "collect_key" => "ck", "label" => "studio-mac",
                               "harness_session_id" => "harness-1", "ends_at" => (Time.now + 600).utc.iso8601 }, env: pin(proj))
      code = run_cli(proj, ["collect", "--code", "ABCD-2345"],
                     "/code" => [200, { "status" => "granted" }],
                     "/collect" => [200, { "slug" => "sess-key", "label" => "studio-mac", "token" => "THE-HARNESS-KEY",
                                           "issued_at" => "2026-10-08T00:00:00Z" }])

      assert_equal HarnessKeyCli::OK, code
      assert_equal %w[/code /collect], @api.calls.map { |c| c[:path][%r{/[a-z]+\z}] }
      assert_equal "ABCD-2345", @api.calls.first[:body]["code"]
      assert_equal "THE-HARNESS-KEY", HarnessKey.token(proj, env: pin(proj))
      assert_includes @out.string, "key length 15"
      refute_includes @out.string + @err.string, "THE-HARNESS-KEY"
    end
  end

  def test_unit_collect_before_the_grant_is_pending_and_a_refusal_names_the_reason
    Dir.mktmpdir do |proj|
      request = { "request" => "login-abc", "collect_key" => "ck", "label" => "studio-mac",
                  "harness_session_id" => "harness-1", "ends_at" => (Time.now + 600).utc.iso8601 }
      HarnessKey.write(proj, request, env: pin(proj))
      assert_equal HarnessKeyCli::PENDING, run_cli(proj, ["collect"], "/collect" => [409, { "error" => "login-abc is pending" }])
      assert_includes @out.string, "still pending"

      assert_equal HarnessKeyCli::FAILED, run_cli(proj, ["collect"], "/collect" => [410, { "error" => "login-abc lapsed" }])
      assert_includes @err.string, "login-abc lapsed (HTTP 410)"
      assert_nil HarnessKey.read(proj, env: pin(proj)), "a lapsed request is forgotten"
    end
  end

  def test_unit_status_reports_the_held_key_by_slug_and_length
    Dir.mktmpdir do |proj|
      assert_equal HarnessKeyCli::OK, run_cli(proj, ["status"])
      assert_includes @out.string, "holds no harness key"

      HarnessKey.write(proj, { "slug" => "sess-key", "label" => "studio-mac", "token" => "THE-HARNESS-KEY" }, env: pin(proj))
      assert_equal HarnessKeyCli::OK, run_cli(proj, ["status"], "/agent_sessions/current" => [200, { "auth" => "harness_key" }])
      assert_equal "THE-HARNESS-KEY", @api.calls.first[:bearer]
      assert_includes @out.string, "sess-key for studio-mac (key length 15); the board accepts it"

      assert_equal HarnessKeyCli::FAILED,
                   run_cli(proj, ["status"], "/agent_sessions/current" => [401, { "error" => "agent session sess-key was revoked" }])
      assert_includes @out.string, "the board refused it: agent session sess-key was revoked (HTTP 401)"
      refute_includes @out.string + @err.string, "THE-HARNESS-KEY"
    end
  end

  def test_unit_an_unknown_command_is_usage
    Dir.mktmpdir { |proj| assert_equal HarnessKeyCli::USAGE, run_cli(proj, ["mint"]) }
  end
end
