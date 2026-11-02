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
require "fileutils"

require File.expand_path("../../bin/lib/task_board", __dir__)
require_relative "../support/op_binary_stub"
# ARMS THE TASK-USAGE SANDBOX FOR THIS PROCESS, and it is load-bearing. This file drives
# TaskBoard.agent_secret, whose vault step is METERED (bin/lib/op_meter.rb), and OpMeter
# writes to the operator's REAL <projects>/.agents/op-reads.log whenever the sandbox is not
# armed. Unarmed, this file's phantom rows make `bin/op-reads` name it a heavy spender of a
# quota it never touched.
# History: task attribute-op-reads-to-caller.
require_relative "../support/task_usage_sandbox"

class TaskBoardTest < Minitest::Test
  # ── [unit] the metering guard this file must keep armed ─────────────────────

  # The regression, pinned at the mechanism rather than at the symptom. Deleting
  # the sandbox require above turns `refused?` false, and the very next
  # agent_secret test appends to the operator's real op-reads.log. Asserting on
  # the log file itself would be worse: it would have to name the real store to
  # check it, which is the thing state_store_containment_test.rb forbids.
  def test_unit_metering_is_refused_so_this_file_cannot_write_the_real_op_reads_log
    assert TaskUsageSandbox.active?,
           "TASK_USAGE_SANDBOX must be armed for this process — without it OpMeter resolves the " \
           "operator's real <projects>/.agents/op-reads.log and records phantom reads for every " \
           "stubbed `op` this file drives."
    assert OpMeter.refused?(ENV),
           "armed and unpinned must REFUSE the write; if this fails, a pin is steering the log " \
           "somewhere and the phantom rows are landing there instead."
  end

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
  # `parse_body` answers `{}` for an unreadable body, so `Array(parse_body(res)["data"])` is
  # `[]` and the count is 0, and for a SAFETY count a broken read resolves toward "proceed".
  # Assert the EFFECT, not the return type: the two readers DIVERGE on an unreadable body, and
  # `[]` from `rows!` means genuinely none.
  # History: task board-parse-silently-returns-empty.

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
  # The chain must not run ENV → 1Password → .env: ENV is unset in agent shells, so the vault
  # read returns and `.env` never runs, spending credentials against a 1,000/day cap shared
  # account-wide. These count READS: an assertion on the returned secret passes on the buggy
  # order too, since vault and .env hold the SAME string in production. The stub prints a
  # different value so the SOURCE is legible, and records every invocation.
  # History: task board-reads-cost-credits.

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

  # ── [unit] agent_secret: the .env branch's UNGUARDED EDGES ──────────────────
  # A malformed .env must fall through to the vault (op.count == 1, "from-vault"), never raise
  # or answer blank: 1Password stays LAST so an unusable .env can still authenticate, and
  # "does not raise" passes on "". THESE PIN THE CONTRACT, NOT ONE MECHANISM. dotenv_secret
  # guards twice on purpose: `File.file?` + `File.readable?`, and `rescue SystemCallError` for
  # the TOCTOU remainder. Dropping EITHER predicate stays GREEN because the rescue catches it.
  # Do not read a surviving single-predicate mutation as dead code.
  # History: task finish-credential-demotion-sweep.
  def test_unit_agent_secret_strips_quotes_off_a_dotenv_value
    Dir.mktmpdir do |dir|
      { %(AGENT_API_SECRET="from-dotenv"\n) => "double",
        %(AGENT_API_SECRET='from-dotenv'\n) => "single" }.each do |body, style|
        dotenv = File.join(dir, ".env")
        File.write(dotenv, body)

        OpBinaryStub.with_stub(TaskBoard, dir: dir) do |op|
          with_env("AGENT_API_SECRET" => nil) do
            assert_equal "from-dotenv", TaskBoard.agent_secret(dotenv),
                         "#{style}-quoted .env value keeps its quotes without the strip, and the " \
                         "quotes would be POSTed as part of the secret"
          end
          assert_equal 0, op.count, "a quoted value is still a usable value — no vault read"
        end
      end
    end
  end

  def test_unit_agent_secret_treats_a_blank_dotenv_value_as_no_value
    # THE SHARPEST EDGE. `AGENT_API_SECRET=` returned "" — TRUTHY in Ruby — so
    # agent_secret short-circuited, the vault fallback never ran, AND every
    # caller's `|| die!` guard failed to fire. The caller proceeded
    # UNAUTHENTICATED and the operator got `KeyError: key not found: "token"`
    # off the auth response instead of a message naming the real problem.
    Dir.mktmpdir do |dir|
      dotenv = File.join(dir, ".env")
      File.write(dotenv, "OTHER=1\nAGENT_API_SECRET=\n")

      OpBinaryStub.with_stub(TaskBoard, dir: dir) do |op|
        with_env("AGENT_API_SECRET" => nil) do
          assert_equal "from-vault", TaskBoard.agent_secret(dotenv),
                       "a set-but-empty .env value must NOT satisfy the chain"
        end
        assert_equal 1, op.count,
                     "and it must reach the vault — the fallback a blank value used to defeat"
      end
    end
  end

  def test_unit_agent_secret_falls_through_a_dotenv_that_is_a_directory
    # `File.exist?` is true for a directory, so the old guard let one straight
    # into File.readlines -> Errno::EISDIR, UNCAUGHT: TaskBoard.agent_secret has
    # no rescue of its own. `File.readable?` alone does NOT close this — a
    # directory IS readable. It takes `File.file?` too.
    Dir.mktmpdir do |dir|
      as_directory = File.join(dir, ".env")
      FileUtils.mkdir_p(as_directory)

      OpBinaryStub.with_stub(TaskBoard, dir: dir) do |op|
        with_env("AGENT_API_SECRET" => nil) do
          assert_equal "from-vault", TaskBoard.agent_secret(as_directory),
                       "a directory .env falls through instead of raising Errno::EISDIR"
        end
        assert_equal 1, op.count
      end
    end
  end

  def test_unit_agent_secret_falls_through_an_unreadable_dotenv
    # The case `File.file?` does NOT close: a mode-000 REGULAR file is still
    # File.file? => true, and File.readlines raises Errno::EACCES. This is why
    # the guard needs BOTH predicates rather than either one.
    Dir.mktmpdir do |dir|
      locked = File.join(dir, ".env")
      File.write(locked, "AGENT_API_SECRET=from-dotenv\n")
      File.chmod(0o000, locked)

      # Stated as an assertion, not a skip: under a uid that can read anything
      # (root) this premise is false and the test below would pass vacuously.
      assert File.file?(locked), "premise: still a regular file"
      refute File.readable?(locked), "premise: unreadable by this uid (fails as root)"

      OpBinaryStub.with_stub(TaskBoard, dir: dir) do |op|
        with_env("AGENT_API_SECRET" => nil) do
          assert_equal "from-vault", TaskBoard.agent_secret(locked),
                       "an unreadable .env falls through instead of raising Errno::EACCES"
        end
        assert_equal 1, op.count
      end
    ensure
      File.chmod(0o600, locked) if locked && File.exist?(locked)
    end
  end

  def test_unit_agent_secret_does_not_let_a_blank_env_short_circuit_the_chain
    # Same defect class one rung up: ENV was returned verbatim when non-empty,
    # so a whitespace-only AGENT_API_SECRET satisfied the chain and skipped both
    # the .env that had the real secret and the vault behind it.
    Dir.mktmpdir do |dir|
      dotenv = File.join(dir, ".env")
      File.write(dotenv, "AGENT_API_SECRET=from-dotenv\n")

      OpBinaryStub.with_stub(TaskBoard, dir: dir) do |op|
        with_env("AGENT_API_SECRET" => "   ") do
          assert_equal "from-dotenv", TaskBoard.agent_secret(dotenv),
                       "a blank ENV is not a secret; the .env below it is"
        end
        assert_equal 0, op.count
      end
    end
  end

  # ── [unit] handed_token: the bearer a parent process passes down ────────────
  #
  # bin/submit mints ONE token per run and exports it in AGENT_API_TOKEN; each
  # child CLI's `token` helper asks here before minting its own. The reader is
  # the whole seam, so its three answers are pinned: a value, a blank, an absence.

  def test_unit_handed_token_reads_the_parents_token_from_the_environment
    assert_equal "tok-from-ship", TaskBoard.handed_token({ "AGENT_API_TOKEN" => "tok-from-ship" })
    assert_equal "tok-trimmed", TaskBoard.handed_token({ "AGENT_API_TOKEN" => "  tok-trimmed\n" }),
                 "a shell export's stray whitespace is not part of the bearer"
  end

  def test_unit_handed_token_is_nil_when_unset_or_blank_so_the_secret_chain_still_runs
    assert_nil TaskBoard.handed_token({})
    assert_nil TaskBoard.handed_token({ "AGENT_API_TOKEN" => "" })
    assert_nil TaskBoard.handed_token({ "AGENT_API_TOKEN" => "   " }),
               "a set-but-blank var is NOT a token — letting it through would send `Bearer ` and 401 every call"
  end

  def test_unit_handed_token_defaults_to_the_process_environment
    with_env("AGENT_API_TOKEN" => "tok-env") { assert_equal "tok-env", TaskBoard.handed_token }
    with_env("AGENT_API_TOKEN" => nil) { assert_nil TaskBoard.handed_token }
  end

  # ── [integration] mint_token: the one POST /api/v1/auth a ship makes ───────

  def test_integration_mint_token_posts_the_secret_and_returns_the_bearer
    with_stub_server(payload: '{"token":"tok-minted","expires_at":"2030-01-01T00:00:00Z"}') do |port, requests|
      token = TaskBoard.mint_token(base_url: "http://127.0.0.1:#{port}", secret: "s3cret")

      assert_equal "tok-minted", token
      req = requests.first
      assert_equal ["POST", "/api/v1/auth"], [req[:method], req[:path]]
      assert_equal({ "secret" => "s3cret" }, JSON.parse(req[:body]))
      assert_nil req[:headers]["authorization"], "the mint itself carries no bearer"
    end
  end

  def test_integration_mint_token_is_nil_when_the_board_answers_without_a_token
    with_stub_server(status: "401 Unauthorized", payload: '{"error":"bad secret","error_code":"UNAUTHORIZED"}') do |port, _|
      assert_nil TaskBoard.mint_token(base_url: "http://127.0.0.1:#{port}", secret: "wrong"),
                 "a refusal is nil, not a raise — the caller (bin/submit) degrades to per-child mints"
    end
    with_stub_server(payload: "<html>502</html>") do |port, _|
      assert_nil TaskBoard.mint_token(base_url: "http://127.0.0.1:#{port}", secret: "s"),
                 "an unreadable body is nil for the same reason"
    end
  end

  def test_unit_mint_token_makes_no_request_without_a_secret
    with_stub_server do |port, requests|
      assert_nil TaskBoard.mint_token(base_url: "http://127.0.0.1:#{port}", secret: nil)
      assert_nil TaskBoard.mint_token(base_url: "http://127.0.0.1:#{port}", secret: "  ")
      assert_empty requests, "a blank secret is not POSTed — the board would only 401 it"
    end
  end

  # ── [integration] keyed_request: the harness key where the board takes it ───

  def test_integration_keyed_request_presents_the_key_and_never_asks_for_the_shared_bearer
    with_stub_server do |port, requests|
      base = "http://127.0.0.1:#{port}"
      TaskBoard.keyed_request(:get, "/api/v1/tasks?stage=building", key: "KEY", fallback: -> { flunk("no shared bearer") }, base_url: base)
      TaskBoard.keyed_request(:patch, "/api/v1/tasks/t", key: "KEY", fallback: -> { flunk("no shared bearer") }, base_url: base,
                                                         body: { "stage" => "building" })
      assert_equal ["Bearer KEY"] * 2, requests.map { |r| r[:headers]["authorization"] }
    end
  end

  def test_integration_keyed_request_presents_the_shared_bearer_off_the_doors_or_with_no_key
    with_stub_server do |port, requests|
      base = "http://127.0.0.1:#{port}"
      TaskBoard.keyed_request(:patch, "/api/v1/tasks/t", key: "KEY", fallback: -> { "SHARED" }, base_url: base, body: { "title" => "T" })
      TaskBoard.keyed_request(:get, "/api/v1/tasks", key: nil, fallback: -> { "SHARED" }, base_url: base)
      assert_equal ["Bearer SHARED"] * 2, requests.map { |r| r[:headers]["authorization"] }
    end
  end

  def test_integration_keyed_request_retries_a_refused_key_with_the_shared_bearer
    refused = []
    with_stub_server(status: "401 Unauthorized", payload: '{"error":"revoked","error_code":"SESSION_ENDED"}') do |port, requests|
      TaskBoard.keyed_request(:get, "/api/v1/tasks", key: "KEY", fallback: -> { "SHARED" }, refused: ->(r) { refused << r.code },
                                                     base_url: "http://127.0.0.1:#{port}")
      assert_equal ["Bearer KEY", "Bearer SHARED"], requests.map { |r| r[:headers]["authorization"] }
    end
    assert_equal ["401"], refused
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

  def test_integration_a_malformed_dotenv_authenticates_from_the_vault_not_a_blank_secret
    # THE CALLER-VISIBLE CONSEQUENCE of the blank-value edge. `AGENT_API_SECRET=` must not
    # resolve to "" (truthy, so the vault is never consulted) and POST `{"secret":""}`: the
    # board answers 401 and a caller's `.fetch("token")` dies with `KeyError: key not found:
    # "token"`, on the wrong layer. Asserted on the WIRE, not the return value: the bytes that
    # reach the board are the point.
    # History: task finish-credential-demotion-sweep.
    Dir.mktmpdir do |dir|
      dotenv = File.join(dir, ".env")
      File.write(dotenv, "OTHER=1\nAGENT_API_SECRET=\n")

      OpBinaryStub.with_stub(TaskBoard, dir: dir) do |op|
        with_stub_server(payload: '{"token":"tok-9"}') do |port, requests|
          with_env("AGENT_API_SECRET" => nil) do
            secret = TaskBoard.agent_secret(dotenv)

            refute_predicate secret.to_s, :empty?,
                             "a blank .env must never resolve to a blank secret"

            res = TaskBoard.request(:post, "/api/v1/auth",
                                    base_url: "http://127.0.0.1:#{port}", body: { secret: secret })
            assert_equal "tok-9", TaskBoard.parse_body(res)["token"]
          end

          assert_equal({ "secret" => "from-vault" }, JSON.parse(requests.first[:body]),
                       "the request carries the VAULT secret — the fallback the blank value defeated")
        end

        assert_equal 1, op.count, "and the vault was consulted exactly once to get there"
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
