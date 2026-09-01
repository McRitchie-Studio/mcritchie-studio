# frozen_string_literal: true

# bin/lib/desk_ledger.rb — the desk ledger's write side, from the CLI.
#
# The whole point of this client is its POSTURE, so that is what these check. It sits on
# bin/agent-worktree's DESTROY path: the caller aborts a teardown when a write fails, so a
# raised SocketError deep inside `remove` would take that decision away from the caller and
# leave a half-torn-down desk — the failure mode the fail-closed rule exists to prevent.
# Every failure must therefore come back as a Result carrying a reason a human can act on.
require "minitest/autorun"
require_relative "../support/session_env"
require_relative "../../bin/lib/desk_ledger"

class DeskLedgerTest < Minitest::Test
  DESK = {
    "worktree" => "/Users/alex/projects/mcritchie-studio/.worktrees/_ship",
    "label" => "mcritchie-studio/_ship",
    "branch" => "release"
  }.freeze

  Response = Struct.new(:code, :body)

  def setup
    # The token memoizes per process; these checks each control their own transport.
    DeskLedger.instance_variable_set(:@token, nil)
  end
  alias teardown setup

  # Records every TaskBoard.request and answers from a script of responses.
  #
  # Plain singleton redefinition rather than Minitest::Mock#stub, deliberately: this file
  # runs BOTH standalone (`ruby -Itest test/lib/desk_ledger_test.rb`, the way every other
  # test/lib check is documented to run) and inside the bundled `bin/rails test` sweep. The
  # standalone lane resolves the SYSTEM minitest, which ships no `minitest/mock` — so a stub
  # here is a check that only runs one of the two ways it is meant to.
  def with_transport(responses, secret: "s3cret")
    calls = []
    original_request = TaskBoard.method(:request)
    original_secret = TaskBoard.method(:agent_secret)

    TaskBoard.define_singleton_method(:request) do |method, path, **kwargs|
      calls << { method: method, path: path, body: kwargs[:body], token: kwargs[:token] }
      response = responses.shift
      raise response if response.is_a?(StandardError)

      response
    end
    TaskBoard.define_singleton_method(:agent_secret) { |_dotenv| secret }

    yield calls
  ensure
    TaskBoard.define_singleton_method(:request, original_request)
    TaskBoard.define_singleton_method(:agent_secret, original_secret)
  end

  AUTH_OK = Response.new("200", '{"token":"tok-abc"}')

  # ---- [unit] the happy path ------------------------------------------------------

  def test_a_filed_record_posts_the_registry_record_verbatim
    with_transport([AUTH_OK, Response.new("201", '{"data":{"id":7}}')]) do |calls|
      result = DeskLedger.file(desk: DESK, status: "removed", source: "remove",
                               safety: "merged", reason: "clean and contained")

      assert_predicate result, :ok?
      assert_equal({ "id" => 7 }, result.record)

      post = calls.last
      desk = post[:body][:desk]

      assert_equal "/api/v1/desk_records", post[:path]
      assert_equal "tok-abc", post[:token]
      assert_equal DESK["worktree"], desk[:worktree_path]
      # The SERVER owns the registry→column mapping (DeskRecord.registry_attributes), so a
      # second mapping here is a second answer waiting to disagree with the first.
      assert_equal DESK, desk[:registry]
      assert_equal "removed", desk[:status]
      assert_equal "merged", desk[:safety]
    end
  end

  # A nil field must be ABSENT, not posted as null: the endpoint's overrides are compacted
  # so an absent value never blanks a column the registry record already filled.
  def test_absent_fields_are_omitted_rather_than_posted_as_null
    with_transport([AUTH_OK, Response.new("201", "{}")]) do |calls|
      DeskLedger.file(desk: DESK, status: "candidate", source: "cleanup")

      desk = calls.last[:body][:desk]

      refute_includes desk.keys, :resolved_on
      refute_includes desk.keys, :actor
    end
  end

  def test_sync_posts_the_whole_registry_under_one_key
    with_transport([AUTH_OK, Response.new("201", '{"data":{"desks":2}}')]) do |calls|
      result = DeskLedger.sync({ "worktrees" => [DESK, DESK] })

      assert_predicate result, :ok?
      assert_equal "/api/v1/desk_records/sync", calls.last[:path]
      assert_equal 2, calls.last[:body][:registry]["worktrees"].size
    end
  end

  # ---- [unit] every failure is a Result, never an exception -----------------------

  def test_a_non_2xx_comes_back_as_a_result_naming_the_status_and_the_body
    with_transport([AUTH_OK, Response.new("500", '{"error":"boom"}')]) do
      result = DeskLedger.file(desk: DESK, status: "removed", source: "remove")

      refute_predicate result, :ok?
      assert_includes result.error, "500"
      assert_includes result.error, "boom",
                      "the caller prints this to an operator mid-teardown; a summary is not enough"
    end
  end

  # THE ONE THAT MATTERS. bin/agent-worktree aborts on `ok == false`; it does not rescue.
  # A raised transport error would blow through the abort and out of the teardown, and the
  # desk's fate would depend on where in the sequence the exception happened to land.
  def test_a_raised_transport_error_is_caught_and_reported_not_propagated
    with_transport([AUTH_OK, SocketError.new("getaddrinfo: nodename nor servname provided")]) do
      result = nil

      assert_nothing_raised { result = DeskLedger.file(desk: DESK, status: "removed", source: "remove") }
      refute_predicate result, :ok?
      assert_includes result.error, "SocketError"
    end
  end

  def test_a_failed_auth_names_the_auth_call_rather_than_the_write
    with_transport([Response.new("401", '{"error":"Invalid or expired token"}')]) do
      result = DeskLedger.file(desk: DESK, status: "removed", source: "remove")

      refute_predicate result, :ok?
      assert_includes result.error, "/api/v1/auth",
                      "an operator must be able to tell a credential problem from a board outage"
    end
  end

  def test_a_missing_secret_says_where_it_looked
    with_transport([], secret: nil) do |calls|
      result = DeskLedger.file(desk: DESK, status: "removed", source: "remove", dotenv: "/repo/.env")

      refute_predicate result, :ok?
      assert_includes result.error, "AGENT_API_SECRET"
      assert_includes result.error, "/repo/.env"
      assert_empty calls, "with no secret there is nothing to post; do not call the board at all"
    end
  end

  # ---- [unit] where it points -----------------------------------------------------

  def test_the_base_url_follows_the_same_env_var_bin_task_reads
    assert_equal "https://mcritchie.studio", DeskLedger.base_url({})
    assert_equal "http://localhost:3000", DeskLedger.base_url({ "TASK_API_BASE" => "http://localhost:3000" })
    assert_equal "https://mcritchie.studio", DeskLedger.base_url({ "TASK_API_BASE" => "  " }),
                 "a set-but-blank value is not a base URL"
  end

  private

  def assert_nothing_raised
    yield
  rescue StandardError => e
    flunk "expected no exception, got #{e.class}: #{e.message}"
  end
end
