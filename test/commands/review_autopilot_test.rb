# frozen_string_literal: true

require "minitest/autorun"
require "open3"
require "tmpdir"
require "socket"
require "json"
require_relative "../support/session_env"

# [integration] A BOARD READ THAT FAILED MUST NOT EXIT 0.
#
# ═══ THE INCIDENT (2026-09-20, arming the merge on PR #1474) ═══
#
# bin/review-autopilot defaulted TASK_BOARD_URL to https://www.mcritchie.studio.
# lib/middleware/canonical_host.rb 301s that alias onto the apex, and
# bin/lib/task_board.rb#request is a bare Net::HTTP call that follows no 3xx — so
# every GET came back 301 while the POSTs, which the middleware does not redirect,
# landed normally. What the operator saw:
#
#   bin/review-autopilot list          "list failed -> HTTP 301"
#   bin/review-autopilot arm <slug>    "!! approval state UNREAD (task read -> HTTP 301)"
#
# and read both as an EXPIRED AGENT TOKEN, because once the code is the only thing
# on the line a 301 looks exactly like a 401. The host default is fixed (1097fbfa,
# pinned by test/lib/board_cli_canonical_host_test.rb) — this file pins the half
# that fix did not touch, and the half that makes the NEXT redirect, outage or
# auth failure survivable.
#
# ═══ WHAT IS ACTUALLY UNDER TEST — THE EXIT CODE, NOT THE HOST ═══
#
# A test asserting BASE_URL's value would pass against a version that still exits
# 0 on a failed read. Two paths did:
#
#   arm --head <sha>   the task GET's status was NEVER checked. `task_body` came
#                      back {} from the lenient parse, the arm POST was sent
#                      anyway, the failure was a WARNING, and the process exited 0.
#   arm (no --head)    same unchecked read, then `die("could not resolve a head
#                      sha", 2)` — non-zero, but exit 2 means REFUSED and the
#                      message blames the caller for a board that was unreachable.
#                      A wrong diagnosis at a mutation boundary, not a near miss.
#
# So the assertions here are the EXIT STATUS and, on arm, THE ABSENCE OF THE WRITE.
# A version that warned and armed anyway would print the same words.
#
# ═══ THE CONTROLS ARE NOT OPTIONAL ═══
#
# `test_list_on_a_readable_board_exits_zero` and `test_arm_on_a_readable_board_arms`
# are what keep the four refusal cases from being vacuous. Without them a script
# that failed unconditionally — a typo in the require, a stub board nothing can
# reach — would satisfy every "exits non-zero" assertion in this file.
class ReviewAutopilotTest < Minitest::Test
  BIN = File.expand_path("../../bin/review-autopilot", __dir__)
  SLUG = "probe-read-failure"
  HEAD = "0123456789abcdef0123456789abcdef01234567"

  # The script's own documented exit codes (see its header):
  #   0 done · 2 refused (bad verdict, bad usage) · 1 could not run (no board)
  # An unreadable board is COULD NOT RUN. The distinction is the whole point: 2
  # tells the operator the tool declined, 1 tells them to go look at the board.
  COULD_NOT_RUN = 1

  # ── the reads that failed ───────────────────────────────────────────────────

  def test_list_on_a_redirect_exits_non_zero
    result = run_cli("list", read_status: 301)

    refute_equal 0, result[:status].exitstatus,
                 "a 301 on the registry read printed a failure and exited 0 — indistinguishable " \
                 "from `nothing armed`, which is the most reassuring sentence this CLI can print"
    assert_equal COULD_NOT_RUN, result[:status].exitstatus
    assert_match(/HTTP 301/, result[:err])
  end

  # The redirect TARGET, and the sentence that stops the next reader diagnosing a
  # credential. A bare "-> HTTP 301" is what cost a session to the wrong theory.
  def test_a_redirect_names_where_it_was_sent_and_that_the_client_will_not_follow
    result = run_cli("list", read_status: 301)

    assert_match %r{https://mcritchie\.studio/api/v1/review_pending_actions}, result[:err],
                 "the failure must name the redirect target; the operator's fix is a URL"
    assert_match(/does not follow redirects/i, result[:err])
    assert_match(/TASK_BOARD_URL/, result[:err])
  end

  # A 401 is the OTHER thing this must not be confused with, so it says so by name.
  def test_an_unauthorized_read_names_the_credential
    result = run_cli("list", read_status: 401)

    assert_equal COULD_NOT_RUN, result[:status].exitstatus
    assert_match(/HTTP 401/, result[:err])
    assert_match(/credential/i, result[:err])
  end

  # ── THE REGRESSION: arm swallowed its task read entirely ────────────────────

  def test_arm_refuses_when_the_task_read_fails_and_sends_no_write
    result = run_cli("arm", SLUG, "--head", HEAD, "--agent", "carl", read_status: 301)

    refute_equal 0, result[:status].exitstatus,
                 "arm reported success on a task read it never checked: with --head supplied the " \
                 "301 was a WARNING and the process exited 0"
    assert_equal COULD_NOT_RUN, result[:status].exitstatus
    assert_empty result[:writes],
                 "arm queued a server-side auto-merge against a task record it could not read. " \
                 "The exit code is the symptom; the write is the damage."
    assert_match(/HTTP 301/, result[:err])
  end

  # Without --head the old code reached `die("could not resolve a head sha", 2)`.
  # Non-zero, so the exit-code assertion alone cannot see this bug — the MESSAGE and
  # the CODE are what separate "the board is unreachable" from "you passed bad flags".
  def test_arm_without_a_head_blames_the_board_not_the_caller
    result = run_cli("arm", SLUG, "--agent", "carl", read_status: 301)

    assert_equal COULD_NOT_RUN, result[:status].exitstatus,
                 "exit 2 files an unreachable board as a REFUSAL — a verdict this tool never made"
    assert_match(/HTTP 301/, result[:err])
    refute_match(/could not resolve a head sha/, result[:err],
                 "the head sha was unresolvable BECAUSE the read failed; naming the symptom " \
                 "sends the reader to --head instead of to the board")
  end

  # ── THE CONTROLS — without these, every case above is vacuous ───────────────

  def test_list_on_a_readable_board_exits_zero
    result = run_cli("list", read_status: 200)

    assert_equal 0, result[:status].exitstatus, result[:err]
    assert_match(/nothing armed/, result[:out])
  end

  # Proves the refusal above is caused by the READ STATUS and not by the harness:
  # same command, same stub, one status changed, and the write lands.
  def test_arm_on_a_readable_board_arms
    result = run_cli("arm", SLUG, "--head", HEAD, "--agent", "carl", read_status: 200)

    assert_equal 0, result[:status].exitstatus, result[:err]
    assert_equal 1, result[:writes].length, "the arm POST should land on a readable board"
    assert_equal HEAD, result[:writes].first["head_sha"]
  end

  private

  # Drive the real script against a stub board, and return its status, streams, and
  # every arm POST it sent.
  #
  # `read_status` is the status the stub gives every GET. The auth POST always
  # succeeds: a stub that 301s the auth too would make the script die there instead,
  # which is a different bug and would pass three of these tests for the wrong reason.
  def run_cli(*args, read_status:)
    Dir.mktmpdir do |dir|
      writes = []
      env = SessionEnv.neutralized(
        TaskUsageSandboxEnv.child_env(dir).merge("AGENT_API_SECRET" => "not-a-real-secret")
      )

      with_board_sink(writes, read_status) do |base|
        out, err, status = Open3.capture3(env.merge("TASK_BOARD_URL" => base), BIN, *args)
        return { out: out, err: err, status: status,
                 writes: writes.filter_map { |w| JSON.parse(w) rescue nil } }
      end
    end
  end

  # A board answering every call the script makes. ROUTING BY PATH MATTERS: a sink
  # that returned one body for everything would answer /auth with a task, the script
  # would die on a missing "token", and that death would read as the refusal.
  #
  # ONLY THE ARM POST IS RECORDED. The auth POST happens on every run, refused or
  # not, so counting it would make the "no write" assertion unfalsifiable.
  def with_board_sink(writes, read_status)
    server = TCPServer.new("127.0.0.1", 0)
    thread = Thread.new do
      while (client = server.accept)
        verb, path = request_line(client)
        payload = read_payload(client)
        writes << payload if payload && verb == "POST" && path.include?("/review_pending_action")

        code, body, location = respond(verb, path, read_status)
        write_response(client, code, body, location)
        client.close
      end
    rescue IOError, Errno::EBADF
      nil
    end
    yield "http://127.0.0.1:#{server.addr[1]}"
  ensure
    server&.close
    thread&.kill
  end

  def request_line(client)
    parts = client.gets.to_s.split(/\s+/)
    [parts[0].to_s, parts[1].to_s]
  end

  def read_payload(client)
    length = 0
    while (line = client.gets) && line.strip != ""
      length = Regexp.last_match(1).to_i if line =~ /^Content-Length:\s*(\d+)/i
    end
    length.positive? ? client.read(length) : nil
  end

  def respond(verb, path, read_status)
    return [200, { token: "sink-bearer" }.to_json, nil] if path.include?("/api/v1/auth")
    return [200, arm_body, nil] if verb == "POST" && path.include?("/review_pending_action")
    return failing_read(path, read_status) unless read_status == 200

    return [200, { data: [] }.to_json, nil] if path.include?("/review_pending_actions")

    [200, { data: task_body }.to_json, nil]
  end

  # The two shapes a failed read really arrives in. The 301 carries an HTML body and
  # a Location header, exactly as ActionDispatch's redirect does — the HTML is what
  # TaskBoard.parse_body leniently reduces to {}, which is how the failure stayed
  # invisible to the code that read `task_body["data"]` off it.
  def failing_read(path, status)
    return [401, { error: "unauthorized" }.to_json, nil] if status == 401

    target = "https://mcritchie.studio#{path}"
    [301, "<html><body>You are being <a href=\"#{target}\">redirected</a>.</body></html>", target]
  end

  def task_body
    { "slug" => SLUG, "title" => "Probe read failure", "stage" => "submitted",
      "metadata" => { "devops" => { "pr_url" => "https://github.com/McRitchie-Studio/mcritchie-studio/pull/1" } } }
  end

  def arm_body
    { data: { "task_slug" => SLUG, "pr_number" => 1, "head_sha" => HEAD, "state" => "armed",
              "base_branch" => "accepted", "verdict" => "merge-ready",
              "expires_at" => "2026-09-21T00:00:00Z" } }.to_json
  end

  def write_response(client, code, body, location)
    headers = ["HTTP/1.1 #{code} #{code == 200 ? "OK" : "Error"}",
               "Content-Type: #{code == 301 ? "text/html" : "application/json"}",
               "Content-Length: #{body.bytesize}"]
    headers << "Location: #{location}" if location
    client.write("#{headers.join("\r\n")}\r\n\r\n#{body}")
  end
end
