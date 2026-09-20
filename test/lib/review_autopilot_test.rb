# frozen_string_literal: true

# bin/review-autopilot — the two board READS under a tool that arms unattended
# merges, and the one property both must hold: a read that FAILED never renders as
# a read that found nothing.
#
# WHY THIS FILE EXISTS (the `list` half). "nothing armed" is the most reassuring
# sentence this CLI can print: it is the operator's answer to "is anything queued
# to merge itself on green CI?". It used to be produced by `body["data"] || []`, so
# a body the CLI could not read — a proxy's HTML error page, a truncated response,
# an expired-token error payload — scored an EMPTY registry and printed the
# all-clear. An armed auto-merge could be sitting there unseen.
#
# WHY IT GREW (the `arm` half, 2026-09-20). Both CLIs defaulted TASK_BOARD_URL to
# https://www.mcritchie.studio; CanonicalHost 301s that alias onto the apex and
# TaskBoard.request follows no 3xx. GETs came back 301 while POSTs, which the
# middleware does not redirect, landed normally — so writes worked and reads did
# not. `arm` never checked its task GET at all: with `--head` supplied the 301 was
# a WARNING, the arm POST went out, and the process EXITED 0. The operator who hit
# it (me) read "-> HTTP 301" as an expired token and went to 1Password, because
# once the code is the only thing on the line a 301 looks exactly like a 401.
#
# The host default is fixed elsewhere (1097fbfa, pinned by
# test/lib/board_cli_canonical_host_test.rb). This file pins the STATUS posture,
# which is what makes the next redirect, outage or auth failure survivable.
#
# The tests assert the EFFECT, not merely the exit code: a check that only asserted
# "exits nonzero" would pass on an unrelated crash, and the things that must never
# happen are the reassuring SENTENCE printing off an unreadable answer and the
# ARM RECEIPT printing off a task record nobody read. `armed: t` on stdout is the
# write's own proof — the script prints it only after the POST succeeds.
#
#   ruby -Itest test/lib/review_autopilot_test.rb
# Also picked up by the normal `bin/rails test` sweep.

require "minitest/autorun"
require "open3"
require "json"
require "socket"
require "rbconfig"
require_relative "../support/session_env"

class ReviewAutopilotTest < Minitest::Test
  BIN = File.expand_path("../../bin/review-autopilot", __dir__)

  # The script's own documented exit codes (its header): 0 done · 2 refused (the
  # standing verdict is not merge-ready, bad usage) · 1 could not run (no board, no
  # secret, no session). An unreadable board is COULD NOT RUN, and the distinction
  # is operational: 2 says the tool declined, 1 says go look at the board.
  COULD_NOT_RUN = 1

  # Serves `payload` verbatim for the registry GET (auth is always canned JSON),
  # so a test can serve exactly what a broken hop puts on the wire.
  def run_list(payload:, status: "200 OK", args: %w[list], location: nil)
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    thread = Thread.new { serve(server, payload, status, location) }

    env = SessionEnv.neutralized(
      "TASK_BOARD_URL" => "http://127.0.0.1:#{port}",
      "AGENT_API_SECRET" => "test-secret"
    )
    Open3.capture3(env, RbConfig.ruby, BIN, *args)
  ensure
    server&.close
    thread&.join(1)
  end

  def serve(server, payload, status, location = nil)
    loop do
      client = server.accept
      line = client.gets
      (client.close; next) if line.nil?

      verb, path, = line.split(" ")
      while (h = client.gets) && h != "\r\n"
        # headers drained; this stub asserts nothing about them
      end

      body = path == "/api/v1/auth" ? JSON.generate("token" => "stub-token") : payload
      code = path == "/api/v1/auth" ? "200 OK" : (status.is_a?(Hash) ? status.fetch(verb) : status)
      # A real 3xx from Rails carries a Location, and the CLI's whole remedy is that
      # URL — a stub that omitted it would verify a message the operator never gets.
      redirect = location && code.start_with?("3") ? "Location: #{location}\r\n" : ""
      client.write("HTTP/1.1 #{code}\r\nContent-Type: application/json\r\n#{redirect}" \
                   "Content-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n#{body}")
      client.close
    end
  rescue IOError, Errno::EBADF, Errno::ECONNRESET
    # server closed — stop serving
  end

  # surface-waiting-request-at-merge: ARM is the last moment a person sees a carried
  # approval request before the unattended merge. One body serves the GET and the POST.
  ARMED = { "slug" => "t", "task_slug" => "t", "pr_number" => 42, "head_sha" => "abc1234567",
            "base_branch" => "accepted", "verdict" => "merge-ready", "expires_at" => "later",
            "metadata" => { "devops" => { "approval_status" => "waiting", "approval_requested_by" => "steffon" } } }.freeze

  def test_arm_shows_a_waiting_approval_request
    out, err, status = run_list(payload: JSON.generate("data" => ARMED), args: %w[arm t --head abc1234567])

    assert status.success?, err
    assert_includes out, "armed: t"
    assert_includes err, "OPERATOR APPROVAL STILL WAITING"
  end

  # THE REGRESSION. This case asserted the OPPOSITE until 2026-09-20 — "the arm
  # itself still lands", plus an `approval state UNREAD` warning — and it passed,
  # because that is exactly what the tool did: with --head supplied, a task GET it
  # never checked let the POST go out and the process exit 0. An auto-merge queued
  # server-side, to run with no reviewer present, against a task record nobody read.
  #
  # The zap that added the UNREAD warning (a053c142) wanted an unverifiable approval
  # state never to pass silently. Refusing the arm is that same intent, enforced
  # instead of announced — so the warning is gone because its branch is now
  # unreachable, not because the concern was dropped.
  #
  # THE LOAD-BEARING ASSERTION IS THE MISSING RECEIPT. `armed: t` prints only after
  # the POST succeeds, so its absence is the write's absence. A version that warned
  # and armed anyway would exit non-zero on some other path and still merge.
  def test_arm_refuses_when_the_task_read_fails_and_never_arms
    out, err, status = run_list(payload: JSON.generate("data" => ARMED), args: %w[arm t --head abc1234567],
                                status: { "GET" => "503 Service Unavailable", "POST" => "200 OK" })

    refute status.success?, "a task read that failed must not exit 0"
    assert_equal COULD_NOT_RUN, status.exitstatus
    refute_includes out, "armed:", "the arm POST went out against a record the CLI could not read"
    assert_includes err, "HTTP 503"
    refute_includes err, "OPERATOR APPROVAL STILL WAITING", "an error body is not a task read"
  end

  # Without --head the old code fell through to `die("could not resolve a head sha", 2)`.
  # NON-ZERO — so an exit-code assertion alone cannot see this one — but exit 2 means
  # REFUSED, a verdict this tool never made, and the message sends the reader to their
  # own flags while the board sits unreachable. That is the misdiagnosis that cost a
  # session on 2026-09-20, reproduced here as a code and a sentence.
  def test_arm_without_a_head_blames_the_board_not_the_caller
    _out, err, status = run_list(payload: JSON.generate("data" => ARMED), args: %w[arm t],
                                 status: { "GET" => "301 Moved Permanently", "POST" => "200 OK" },
                                 location: "https://mcritchie.studio/api/v1/tasks/t")

    assert_equal COULD_NOT_RUN, status.exitstatus,
                 "exit 2 files an unreachable board as a REFUSAL"
    assert_includes err, "HTTP 301"
    refute_includes err, "could not resolve a head sha",
                     "the head was unresolvable BECAUSE the read failed; naming the symptom " \
                     "sends the reader to --head instead of to the board"
  end

  # The redirect TARGET and the env var that produced it. A bare "-> HTTP 301" is
  # what got read as an expired token: the number is not a diagnosis.
  def test_a_redirect_names_its_target_and_that_the_client_will_not_follow
    _out, err, status = run_list(payload: "<html>redirected</html>", status: "301 Moved Permanently",
                                 location: "https://mcritchie.studio/api/v1/review_pending_actions")

    assert_equal COULD_NOT_RUN, status.exitstatus
    assert_includes err, "https://mcritchie.studio/api/v1/review_pending_actions",
                    "the redirect target IS the operator's fix"
    assert_match(/does not follow redirects/i, err)
    assert_includes err, "TASK_BOARD_URL"
  end

  # The complement: a 401 is the thing every other code was being mistaken for, so
  # it is the one code allowed to say it.
  def test_an_unauthorized_read_names_the_credential
    _out, err, status = run_list(payload: JSON.generate("error" => "Unauthorized"),
                                 status: "401 Unauthorized")

    assert_equal COULD_NOT_RUN, status.exitstatus
    assert_includes err, "HTTP 401"
    assert_match(/credential/i, err)
    refute_match(/redirect/i, err)
  end

  def test_an_unreadable_registry_refuses_instead_of_printing_nothing_armed
    out, err, status = run_list(payload: "<html><body>502 Bad Gateway</body></html>")

    refute status.success?, "an unreadable registry must not exit 0"
    refute_includes out, "nothing armed",
                     "the all-clear must never print off a body the CLI could not read"
    assert_includes err, "UNREADABLE"
    assert_includes err, "This is NOT \"nothing armed\""
  end

  def test_an_error_payload_is_refused_too
    # An expired 24h agent token, served 200-shaped by a proxy: valid JSON,
    # carrying no rows. A lenient read scores it as an empty registry.
    out, err, status = run_list(payload: JSON.generate("error" => "Unauthorized"))

    refute status.success?
    refute_includes out, "nothing armed"
    assert_includes err, "UNREADABLE"
  end

  def test_a_genuinely_empty_registry_still_says_nothing_armed
    # The control. Refusing THIS would be a worse bug than the one being fixed:
    # empty-because-true is the normal, healthy answer.
    out, _err, status = run_list(payload: JSON.generate("data" => []))

    assert status.success?, "an empty registry is a healthy answer"
    assert_includes out, "nothing armed"
  end

  def test_an_armed_action_is_listed
    action = { "task_slug" => "some-task", "state" => "armed", "head_sha" => "abc1234567",
               "pr_number" => 42, "base_branch" => "accepted", "verdict" => "merge-ready",
               "note" => "waiting on CI" }
    out, _err, status = run_list(payload: JSON.generate("data" => [action]))

    assert status.success?
    refute_includes out, "nothing armed"
    assert_includes out, "some-task"
  end
end
