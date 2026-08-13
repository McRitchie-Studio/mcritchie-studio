# frozen_string_literal: true

# [integration] `bin/task bounces` and the breaker gate on `bin/task block --kind
# rework`, driven end-to-end against a localhost stub board (no Rails, no real
# network) — status line, parse, classification, exit code, and what goes on the wire.
#
# WHY AN INTEGRATION TIER AT ALL, when BounceLedger is unit-tested next door.
# Because the defect being fixed lived in the SEAM, not in anybody's logic: the
# recipe fetched a real response and then read it wrong. A unit test that hands the
# ledger a hash can never catch a CLI that forgets to parse — so this file gives the
# CLI a real socket, a real Net::HTTPResponse, and a real 401, and asserts the
# breaker's ANSWER rather than its internals.
#
#   ruby -Itest test/lib/bounce_check_cli_test.rb
# Also picked up by the normal `bin/rails test` sweep.

require "minitest/autorun"
require "json"
require "socket"
require "open3"
require "rbconfig"
require "tmpdir"
require "fileutils"
require_relative "../support/session_env"

class BounceCheckCliTest < Minitest::Test
  BIN = File.expand_path("../../bin/task", __dir__)
  SLUG = "demo-task"
  EXIT_BREAKER_TRIPPED = 10

  def setup
    @sandbox_root = Dir.mktmpdir("bounces-cli-sandbox")
  end

  def teardown
    FileUtils.remove_entry(@sandbox_root) if @sandbox_root && File.directory?(@sandbox_root)
  end

  # One qa_feedback row as the activities API renders it.
  def row(kind: "rework", summary: "Fixture drift in the board test", at: "2026-08-01T12:00:00Z")
    metadata = { "summary" => summary }
    metadata["kind"] = kind if kind
    { "created_at" => at, "activity_type" => "qa_feedback", "agent_slug" => "carl",
      "description" => summary, "metadata" => metadata }
  end

  def activities_payload(rows)
    JSON.generate("data" => rows,
                  "meta" => { "page" => 1, "per_page" => 100, "total" => rows.size, "total_pages" => 1 })
  end

  # Run bin/task against a stub board. `activities` is [status, body] for the
  # GET /api/v1/activities read — the seam under test. `task` is [status, body] for
  # the GET /api/v1/tasks/:slug existence check.
  def run_task(args, activities:, task: nil)
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    requests = []
    thread = Thread.new { serve(server, requests, activities, task) }

    env = SessionEnv.neutralized({
      "TASK_API_BASE" => "http://127.0.0.1:#{port}",
      "AGENT_API_SECRET" => "test-secret"
    }.merge(TaskUsageSandboxEnv.child_env(@sandbox_root)))

    out, err, status = Open3.capture3(env, RbConfig.ruby, BIN, *args)
    [out, err, status, requests]
  ensure
    server&.close
    thread&.join(1)
  end

  def serve(server, requests, activities, task = nil)
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
      body = headers["content-length"] ? client.read(headers["content-length"].to_i) : ""
      requests << { method: method, path: path, body: body }

      code, payload =
        if path.start_with?("/api/v1/auth")
          [200, JSON.generate("token" => "stub-token")]
        elsif path.start_with?("/api/v1/activities") && method == "GET"
          activities
        elsif path.start_with?("/api/v1/activities")
          [200, JSON.generate("data" => { "slug" => "activity-1" })]
        elsif task && method == "GET" && path.start_with?("/api/v1/tasks/")
          task
        else
          [200, JSON.generate("data" => { "slug" => SLUG, "stage" => "building", "title" => "Demo",
                                          "metadata" => { "devops" => {} } })]
        end

      client.write("HTTP/1.1 #{code} #{code == 200 ? "OK" : "Error"}\r\nContent-Type: application/json\r\n" \
                   "Content-Length: #{payload.bytesize}\r\nConnection: close\r\n\r\n#{payload}")
      client.close
    end
  rescue IOError, Errno::EBADF, Errno::ECONNRESET
    nil # server closed — stop serving
  end

  def posted_activity(requests)
    request = requests.find { |r| r[:method] == "POST" && r[:path] == "/api/v1/activities" }
    request && JSON.parse(request[:body])
  end

  # ---------------------------------------------------------------------------
  # THE EFFECT — two prior send-backs, over the wire, report TWO.
  # ---------------------------------------------------------------------------

  def test_two_prior_send_backs_report_two_and_exit_tripped
    out, err, status = run_task(["bounces", SLUG],
                                activities: [200, activities_payload([row, row(at: "2026-08-03T09:12:00Z")])])

    assert_equal EXIT_BREAKER_TRIPPED, status.exitstatus, "a tripped breaker exits 10 (REFUSED): #{err}"
    assert_match(/BREAKER: TRIPPED — 2 prior send-back/, out)
    assert_match(/--kind dependency/, out, "a tripped breaker must name the ESCALATION, not just refuse")
  end

  def test_a_clean_task_is_clear_and_exits_zero
    out, _err, status = run_task(["bounces", SLUG], activities: [200, activities_payload([])])

    assert_predicate status, :success?
    assert_match(/BREAKER: CLEAR/, out)
  end

  # The read must actually FILTER — a breaker that counted every activity type
  # would trip on ordinary comments.
  def test_the_read_is_filtered_to_qa_feedback_for_this_task
    _out, _err, _status, requests = run_task(["bounces", SLUG], activities: [200, activities_payload([])])
    get = requests.find { |r| r[:method] == "GET" && r[:path].start_with?("/api/v1/activities") }

    refute_nil get, "expected a GET /api/v1/activities"
    assert_includes get[:path], "task_slug=#{SLUG}"
    assert_includes get[:path], "activity_type=qa_feedback"
  end

  # MUTATION — a slug that does not exist. THE SAME DEFECT, ONE LAYER OUT, and
  # found by the first smoke test of this very command: the activities endpoint
  # filters by task_slug and answers 200 with an EMPTY data array for a slug nobody
  # has ever heard of. A typo, a renamed slug, or a stale handle therefore scored
  # zero bounces and green-lit the block — a wrong usage yielding the safe-looking
  # answer, which is the exact shape this task exists to end.
  def test_an_unknown_slug_is_refused_and_never_reported_clear
    out, err, status = run_task(["bounces", "no-such-task-xyz"],
                                activities: [200, activities_payload([])],
                                task: [404, JSON.generate("error" => "task not found")])

    refute_equal 0, status.exitstatus, "an unknown task must NOT exit 0 — 0 means CLEAR"
    refute_match(/CLEAR/, out, "a slug nobody has heard of is not a task with a clean record")
    assert_match(/task not found/i, err)
  end

  def test_a_rework_block_on_an_unknown_slug_never_lands
    _out, _err, status, requests = run_task(
      ["block", "no-such-task-xyz", "--kind", "rework", "--feedback", "x"],
      activities: [200, activities_payload([])],
      task: [404, JSON.generate("error" => "task not found")]
    )

    refute_predicate status, :success?
    assert_nil posted_activity(requests)
  end

  # ---------------------------------------------------------------------------
  # MUTATION — a 401. The auth failure that silently DISARMED the breaker.
  # ---------------------------------------------------------------------------

  def test_a_401_read_reports_unknown_and_never_clear
    out, err, status = run_task(
      ["bounces", SLUG],
      activities: [401, JSON.generate("error" => "invalid token", "error_code" => "UNAUTHORIZED")]
    )

    refute_equal 0, status.exitstatus, "an unreadable ledger must NOT exit 0 — 0 means CLEAR"
    assert_match(/BREAKER: UNKNOWN/, err)
    assert_match(/401/, err)
    refute_match(/CLEAR/, out, "a failed read must never print a CLEAR verdict")
    refute_match(/\b0 prior\b/, out, "this is the defect verbatim: an auth failure answering zero")
  end

  # ---------------------------------------------------------------------------
  # MUTATION — an unparsed / unparseable body. THE original defect's shape.
  # ---------------------------------------------------------------------------

  def test_a_non_json_body_reports_unknown_and_never_clear
    out, err, status = run_task(["bounces", SLUG],
                                activities: [200, "<!DOCTYPE html><title>Application error</title>"])

    refute_equal 0, status.exitstatus, "an unparseable body must NOT exit 0"
    assert_match(/BREAKER: UNKNOWN/, err)
    refute_match(/CLEAR/, out)
  end

  def test_a_200_with_no_data_array_reports_unknown_and_never_clear
    out, err, status = run_task(["bounces", SLUG], activities: [200, JSON.generate("meta" => { "total" => 0 })])

    refute_equal 0, status.exitstatus
    assert_match(/BREAKER: UNKNOWN/, err)
    refute_match(/CLEAR/, out)
  end

  # UNKNOWN and TRIPPED must be DISTINGUISHABLE by exit code. Collapsing them
  # would make "the read broke" indistinguishable from "escalate to the operator".
  def test_unknown_and_tripped_use_different_exit_codes
    _o1, _e1, unknown = run_task(["bounces", SLUG], activities: [401, JSON.generate("error" => "nope")])
    _o2, _e2, tripped = run_task(["bounces", SLUG], activities: [200, activities_payload([row])])

    refute_equal unknown.exitstatus, tripped.exitstatus
    assert_equal EXIT_BREAKER_TRIPPED, tripped.exitstatus
  end

  # ---------------------------------------------------------------------------
  # THE GATE — a rework block on a tripped task is REFUSED before it lands.
  # ---------------------------------------------------------------------------

  def test_a_rework_block_is_refused_when_the_breaker_is_tripped
    _out, err, status, requests = run_task(
      ["block", SLUG, "--kind", "rework", "--feedback", "again"],
      activities: [200, activities_payload([row])]
    )

    assert_equal EXIT_BREAKER_TRIPPED, status.exitstatus, "the second bounce must be refused: #{err}"
    assert_match(/BREAKER: TRIPPED/, err)
    assert_match(/--kind dependency/, err, "the refusal must name the escalation it routes to")
    assert_nil posted_activity(requests), "REFUSED means the bounce never lands — not a receipt after the fact"
    refute requests.any? { |r| r[:path].end_with?("/block") },
           "the task must not be blocked when the breaker refuses"
  end

  # A MECHANICAL bounce (red CI, a merge conflict) has nothing for the operator to
  # arbitrate, so it proceeds — but only on a RECORDED acknowledgment.
  def test_an_acknowledged_mechanical_bounce_proceeds_and_records_the_reason
    _out, err, status, requests = run_task(
      ["block", SLUG, "--kind", "rework", "--feedback", "CI is red", "--breaker-ack", "red CI, mechanical"],
      activities: [200, activities_payload([row])]
    )

    assert_predicate status, :success?, "an acknowledged mechanical bounce proceeds: #{err}"
    activity = posted_activity(requests)
    refute_nil activity, "the bounce must land"
    assert_equal "red CI, mechanical", activity.dig("metadata", "breaker_ack"),
                 "an override must leave EVIDENCE on the record, or it is just a bypass"
  end

  # An escalation is not a re-block, so the breaker must never stand in its way —
  # otherwise a tripped task has no legal move at all.
  def test_a_dependency_escalation_is_never_refused
    _out, err, status, requests = run_task(
      ["block", SLUG, "--kind", "dependency", "--feedback", "both positions"],
      activities: [200, activities_payload([row, row])]
    )

    assert_predicate status, :success?, "the escalation the breaker ROUTES TO must always be available: #{err}"
    assert_equal "dependency", posted_activity(requests).dig("metadata", "kind")
  end

  def test_an_environment_block_is_never_refused
    _out, err, status = run_task(["block", SLUG, "--kind", "environment", "--feedback", "devnet down"],
                                 activities: [200, activities_payload([row])])

    assert_predicate status, :success?, "a blocked desk is not a send-back: #{err}"
  end

  # THE LEDGER'S OWN INTEGRITY — the kind has to reach the row, or the next read
  # cannot classify it and the over-count comes straight back.
  def test_a_rework_block_stamps_its_kind_on_the_activity
    _out, err, status, requests = run_task(
      ["block", SLUG, "--kind", "rework", "--feedback", "first bounce", "--summary", "Missing regression test"],
      activities: [200, activities_payload([])]
    )

    assert_predicate status, :success?, err
    activity = posted_activity(requests)
    assert_equal "rework", activity.dig("metadata", "kind"),
                 "the block_kind COLUMN is wiped by a compliant resubmission — this row is the durable record"
    assert_equal "Missing regression test", activity.dig("metadata", "summary"),
                 "stamping the kind must not displace the existing summary"
  end

  # The gate must not fail OPEN when the ledger cannot be read: an unreadable
  # ledger is exactly the state in which the breaker's verdict is unknown.
  def test_a_rework_block_refuses_when_the_ledger_cannot_be_read
    _out, err, status, requests = run_task(["block", SLUG, "--kind", "rework", "--feedback", "again"],
                                           activities: [401, JSON.generate("error" => "invalid token")])

    refute_predicate status, :success?, "an unreadable ledger must not silently permit the bounce"
    assert_match(/circuit breaker cannot be evaluated/, err)
    assert_nil posted_activity(requests)
  end

  def test_breaker_ack_is_rejected_on_a_non_rework_block
    _out, err, status = run_task(["block", SLUG, "--kind", "environment", "--feedback", "x", "--breaker-ack", "y"],
                                 activities: [200, activities_payload([])])

    refute_predicate status, :success?
    assert_match(/only applies to --kind rework/, err)
  end
end
