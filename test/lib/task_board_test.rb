# frozen_string_literal: true

# Tests for bin/lib/task_board.rb — the shared task-board TRANSPORT under
# bin/task, bin/dor-check, bin/reviewer-select, bin/session-preflight and
# bin/devops-cycle. The module is deliberately posture-free (raw response back,
# no status check, no rescue) so each CLI keeps its exact error behavior; these
# tests pin the transport shape, the lenient parse, and the ENV-first secret.
#   ruby -Itest test/lib/task_board_test.rb
# Also picked up by the normal `bin/rails test` sweep.

require "minitest/autorun"
require "json"
require "socket"
require "tmpdir"

require File.expand_path("../../bin/lib/task_board", __dir__)
require_relative "../support/op_binary_stub"

class TaskBoardTest < Minitest::Test
  # ── [unit] parse_body (the die!-family's lenient parse) ─────────────────────

  def test_unit_parse_body_returns_empty_hash_for_blank_or_invalid_bodies
    assert_equal({}, TaskBoard.parse_body(FakeResponse.new("")))
    assert_equal({}, TaskBoard.parse_body(FakeResponse.new(nil)))
    assert_equal({}, TaskBoard.parse_body(FakeResponse.new("<html>boom</html>")),
                 "a non-JSON error page still renders a verdict, never raises")
  end

  def test_unit_parse_body_parses_json
    assert_equal({ "data" => [1] }, TaskBoard.parse_body(FakeResponse.new('{"data":[1]}')))
  end

  # ── [unit] rows!: the STRICT reader every COUNTING caller must use ──────────
  #
  # THE DEFECT THESE PIN. `parse_body` answers `{}` for a body it could not read,
  # so `parse_body(res)["data"]` is nil, `Array(nil)` is `[]`, and the count is 0
  # — no exception, no warning, and an answer shaped exactly like the good news
  # the caller was hoping for. For a SAFETY count, empty IS the reassuring
  # answer, so a broken read always resolves toward "proceed".
  #
  # So these assert the EFFECT, not the return type: a test that `rows!` gives
  # back a collection would pass blind on the buggy version too. What is asserted
  # is that the two readers DIVERGE on an unreadable body, and that `[]` from
  # `rows!` means genuinely none.

  def test_unit_rows_refuses_a_non_json_body_where_the_lenient_parse_scores_zero
    html = FakeResponse.new("<html><title>502 Bad Gateway</title></html>", "502")

    # The old path — silently zero. This is the bug, held still.
    assert_equal 0, Array(TaskBoard.parse_body(html)["data"]).size,
                 "the lenient parse scores an unreadable body as ZERO rows"

    error = assert_raises(TaskBoard::UnreadableResponse) { TaskBoard.rows!(html) }
    assert_match(/not JSON/, error.message)
    assert_match(/HTTP 502/, error.message, "the status is the first thing a reader wants")
  end

  def test_unit_rows_refuses_an_empty_body
    error = assert_raises(TaskBoard::UnreadableResponse) { TaskBoard.rows!(FakeResponse.new("")) }
    assert_match(/EMPTY body/, error.message)

    assert_raises(TaskBoard::UnreadableResponse, "a nil body is unreadable too") do
      TaskBoard.rows!(FakeResponse.new(nil))
    end
  end

  def test_unit_rows_refuses_an_error_payload_instead_of_counting_it_as_none
    # An expired 24h agent token is the live vector: a 401 has no rows either, and
    # scoring it zero silently DISARMS whatever safety count asked the question.
    unauthorized = FakeResponse.new('{"error":"Unauthorized","error_code":"UNAUTHORIZED"}', "401")

    assert_equal 0, Array(TaskBoard.parse_body(unauthorized)["data"]).size,
                 "the lenient parse reads an auth failure as zero rows"

    error = assert_raises(TaskBoard::UnreadableResponse) { TaskBoard.rows!(unauthorized) }
    assert_match(/returned an error/, error.message)
    assert_match(/UNAUTHORIZED/, error.message)
  end

  def test_unit_rows_refuses_a_payload_carrying_no_data_array
    error = assert_raises(TaskBoard::UnreadableResponse) do
      TaskBoard.rows!(FakeResponse.new('{"meta":{"total":3}}', "200"))
    end
    assert_match(/no `data` array/, error.message)
    assert_match(/NOT an empty one/, error.message)
  end

  def test_unit_rows_returns_the_rows_and_distinguishes_a_genuinely_empty_answer
    assert_equal [ 1, 2 ], TaskBoard.rows!(FakeResponse.new('{"data":[1,2]}', "200"))
    assert_equal [], TaskBoard.rows!(FakeResponse.new('{"data":[]}', "200")),
                 "a list endpoint that SUCCEEDED always carries its array — [] here means none"
  end

  def test_unit_rows_reads_an_alternate_key
    assert_equal [ "a" ], TaskBoard.rows!(FakeResponse.new('{"items":["a"]}', "200"), key: "items")
  end

  # ── [unit] parse_body!: the strict parse under rows! ────────────────────────

  def test_unit_parse_body_bang_returns_the_payload_including_an_error_payload
    assert_equal({ "data" => [ 1 ] }, TaskBoard.parse_body!(FakeResponse.new('{"data":[1]}', "200")))
    assert_equal({ "error" => "nope" }, TaskBoard.parse_body!(FakeResponse.new('{"error":"nope"}', "422")),
                 "a caller that wants to RENDER the board's error still gets it; rows! is what refuses one")
  end

  def test_unit_parse_body_bang_refuses_a_non_object_payload
    error = assert_raises(TaskBoard::UnreadableResponse) { TaskBoard.parse_body!(FakeResponse.new("[1,2]", "200")) }
    assert_match(/expected a JSON object/, error.message)
  end

  def test_unit_parse_body_bang_names_the_mistake_when_handed_something_that_is_not_a_response
    error = assert_raises(TaskBoard::UnreadableResponse) { TaskBoard.parse_body!({ "data" => [] }) }
    assert_match(/expected an HTTP response/, error.message)
  end

  # ── [unit] agent_secret: the ORDER, measured in VAULT READS ─────────────────
  #
  # THE DEFECT THESE PIN. The chain used to run ENV → 1Password → .env. ENV is
  # unset in agent shells, so the vault read SUCCEEDED and RETURNED, and the
  # .env branch below it never ran on a provisioned machine. Every `bin/task`
  # invocation therefore spent one credential against a 1,000/day cap shared
  # account-wide by every lane — 1,308 invocations measured in one session — to
  # fetch a secret sitting in the repo's own .env.
  #
  # So these count READS, not just return values. An assertion on the returned
  # secret alone would pass on the BUGGY order too: in production the vault and
  # the .env hold the SAME string, which is precisely why this went unseen. The
  # stub prints a different value so the SOURCE is legible, and records every
  # invocation so "was the vault consulted at all?" is answerable.

  def test_unit_agent_secret_takes_the_dotenv_and_spends_no_vault_read
    Dir.mktmpdir do |dir|
      dotenv = File.join(dir, ".env")
      File.write(dotenv, "OTHER=1\nAGENT_API_SECRET=from-dotenv\n")

      OpBinaryStub.with_stub(TaskBoard, dir: dir) do |op|
        with_env("AGENT_API_SECRET" => nil) do
          assert_equal "from-dotenv", TaskBoard.agent_secret(dotenv),
                       "the .env is consulted BEFORE the vault (old order answered 'from-vault')"
        end
        assert_equal 0, op.count,
                     "a provisioned machine must spend ZERO credentials resolving the board secret"
      end
    end
  end

  def test_unit_agent_secret_still_reaches_the_vault_when_there_is_no_dotenv
    # The branch is DEMOTED, not deleted: a fresh machine mid-bootstrap has no
    # .env and the vault is its only way to authenticate. Deleting it would pass
    # the test above and brick a bootstrap.
    Dir.mktmpdir do |dir|
      absent = File.join(dir, "not-provisioned", ".env")

      OpBinaryStub.with_stub(TaskBoard, dir: dir) do |op|
        with_env("AGENT_API_SECRET" => nil) do
          assert_equal "from-vault", TaskBoard.agent_secret(absent)
          assert_equal "from-vault", TaskBoard.agent_secret(absent), "second resolution, same run"
        end

        assert_equal 1, op.count,
                     "the vault answers ONCE per process — several subcommands resolve the secret " \
                     "more than once per run, and each unmemoized retry would bill"
        assert_equal ["read #{TaskBoard::SECRET_REF}"], op.lines,
                     "and it asks for the agent-vault ref, not some other item"
      end
    end
  end

  def test_unit_agent_secret_prefers_the_env_verbatim
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, ".env"), "AGENT_API_SECRET=from-dotenv\n")

      OpBinaryStub.with_stub(TaskBoard, dir: dir) do |op|
        with_env("AGENT_API_SECRET" => "from-env") do
          assert_equal "from-env", TaskBoard.agent_secret(File.join(dir, ".env"))
        end
        assert_equal 0, op.count, "ENV short-circuits before either file or vault"
      end
    end
  end

  def test_unit_agent_secret_survives_a_nil_dotenv_path
    # bin/devops-reconcile calls `TaskBoard.agent_secret(nil)`, and
    # `File.exist?(nil)` raises TypeError. That cost nothing while the .env
    # branch sat unreachable behind a vault read that always returned; promoting
    # .env AHEAD of the vault is exactly what arms it. Guarded in the method.
    Dir.mktmpdir do |dir|
      OpBinaryStub.with_stub(TaskBoard, dir: dir) do |op|
        with_env("AGENT_API_SECRET" => nil) do
          assert_equal "from-vault", TaskBoard.agent_secret(nil),
                       "a nil dotenv path falls through to the vault instead of raising"
        end
        assert_equal 1, op.count
      end
    end
  end

  # ── [integration] request shape against a localhost stub ────────────────────

  def test_integration_request_sends_bearer_and_json_body
    with_stub_server do |port, requests|
      res = TaskBoard.request(:post, "/api/v1/tasks",
                              base_url: "http://127.0.0.1:#{port}",
                              token: "tok-1", body: { "title" => "X" })

      assert_equal "200", res.code
      req = requests.first
      assert_equal "POST", req[:method]
      assert_equal "Bearer tok-1", req[:headers]["authorization"]
      assert_equal "application/json", req[:headers]["content-type"]
      assert_equal({ "title" => "X" }, JSON.parse(req[:body]))
    end
  end

  def test_integration_request_get_without_token_or_body
    with_stub_server do |port, requests|
      res = TaskBoard.request(:get, "/api/v1/tasks/slug", base_url: "http://127.0.0.1:#{port}")

      assert_equal "200", res.code
      req = requests.first
      assert_equal "GET", req[:method]
      assert_nil req[:headers]["authorization"], "no token → no Authorization header"
      assert_equal "", req[:body].to_s
    end
  end

  def test_integration_request_supports_patch_for_bin_task_moves
    with_stub_server do |port, requests|
      TaskBoard.request(:patch, "/api/v1/tasks/slug",
                        base_url: "http://127.0.0.1:#{port}", token: "t", body: { "stage" => "building" })
      assert_equal "PATCH", requests.first[:method]
    end
  end

  def test_integration_request_accepts_a_prebuilt_uri_with_query
    with_stub_server do |port, requests|
      uri = URI.join("http://127.0.0.1:#{port}", "/api/v1/tasks")
      uri.query = URI.encode_www_form(stage: "submitted", page: 1)
      TaskBoard.request(:get, uri, token: "t")

      assert_equal "/api/v1/tasks?stage=submitted&page=1", requests.first[:path],
                   "devops-cycle passes prebuilt URIs to carry pagination query strings"
    end
  end

  def test_integration_request_never_checks_status_and_never_rescues
    with_stub_server(status: "422 Unprocessable Entity", payload: '{"error":"nope"}') do |port, _requests|
      res = TaskBoard.request(:post, "/x", base_url: "http://127.0.0.1:#{port}", body: {})
      assert_equal "422", res.code, "the raw response comes back — the CALLER owns the error posture"
    end

    assert_raises(SystemCallError, "transport errors PROPAGATE — bin/task's crash posture is the caller's") do
      TaskBoard.request(:get, "/x", base_url: "http://127.0.0.1:1", read_timeout: 1)
    end
  end

  # ── [integration] the two readers against a REAL board answer ───────────────

  def test_integration_a_counting_read_of_an_html_error_page_refuses_instead_of_zero
    # A reverse proxy in front of the board serves HTML, not JSON, and does it
    # with a 200 often enough that a status check alone would not catch it.
    page = "<!DOCTYPE html><html><body>Application error</body></html>"

    with_stub_server(payload: page) do |port, _requests|
      res = TaskBoard.request(:get, "/api/v1/activities?activity_type=qa_feedback",
                              base_url: "http://127.0.0.1:#{port}", token: "t")

      assert_equal "200", res.code, "the transport is happy — only the BODY is unreadable"
      assert_equal 0, Array(TaskBoard.parse_body(res)["data"]).size,
                   "counting through the lenient parse answers zero and lets the caller proceed"
      assert_raises(TaskBoard::UnreadableResponse) { TaskBoard.rows!(res) }
    end
  end

  def test_integration_a_counting_read_of_a_healthy_empty_list_answers_none
    with_stub_server(payload: '{"data":[],"meta":{"total":0}}') do |port, _requests|
      res = TaskBoard.request(:get, "/api/v1/activities", base_url: "http://127.0.0.1:#{port}", token: "t")

      assert_equal [], TaskBoard.rows!(res),
                   "empty-because-true still answers — refusing THAT would be the worse bug"
    end
  end

  # ── [integration] a whole board call, priced in credentials ─────────────────

  def test_integration_a_board_call_resolves_and_authenticates_without_a_vault_read
    # The acceptance criterion end to end: resolve the secret the way a CLI does,
    # then actually mint a token with it against a live localhost board. The
    # count that matters is taken across BOTH steps, because the defect was never
    # visible in either one alone — it was visible in the daily total.
    Dir.mktmpdir do |dir|
      dotenv = File.join(dir, ".env")
      File.write(dotenv, "AGENT_API_SECRET=from-dotenv\n")

      OpBinaryStub.with_stub(TaskBoard, dir: dir) do |op|
        with_stub_server(payload: '{"token":"tok-9"}') do |port, requests|
          with_env("AGENT_API_SECRET" => nil) do
            secret = TaskBoard.agent_secret(dotenv)
            res = TaskBoard.request(:post, "/api/v1/auth",
                                    base_url: "http://127.0.0.1:#{port}", body: { secret: secret })

            assert_equal "tok-9", TaskBoard.parse_body(res)["token"], "the board accepted the .env secret"
          end

          assert_equal({ "secret" => "from-dotenv" }, JSON.parse(requests.first[:body]),
                       "and it authenticated with the LOCAL secret, not a vault copy")
        end

        assert_equal 0, op.count,
                     "one full board call spends zero 1Password reads — the old order spent one PER CALL"
      end
    end
  end

  private

  # `code` is optional — the strict readers only decorate their message with it,
  # they never branch on it (status posture stays the caller's, per the module).
  FakeResponse = Struct.new(:body, :code)

  def with_env(pairs)
    saved = pairs.keys.map { |k| [k, ENV[k]] }.to_h
    pairs.each { |k, v| ENV[k] = v }
    yield
  ensure
    saved.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end

  # One-connection-at-a-time localhost stub recording every request.
  def with_stub_server(status: "200 OK", payload: '{"data":{}}')
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    requests = []
    thread = Thread.new { serve(server, requests, status, payload) }
    yield port, requests
  ensure
    server&.close
    thread&.join(1)
  end

  def serve(server, requests, status, payload)
    loop do
      client = server.accept
      line = client.gets
      (client.close; next) if line.nil?

      method, path, = line.split(" ")
      headers = {}
      while (h = client.gets) && h != "\r\n"
        k, v = h.split(":", 2)
        headers[k.strip.downcase] = v.strip if v
      end
      len = headers["content-length"]
      body = len ? client.read(len.to_i) : ""
      requests << { method: method, path: path, headers: headers, body: body }

      client.write("HTTP/1.1 #{status}\r\nContent-Type: application/json\r\n" \
                   "Content-Length: #{payload.bytesize}\r\nConnection: close\r\n\r\n#{payload}")
      client.close
    end
  rescue IOError, Errno::EBADF, Errno::ECONNRESET
    # server closed — stop serving
  end
end
