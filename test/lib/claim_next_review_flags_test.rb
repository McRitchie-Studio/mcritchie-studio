# frozen_string_literal: true

# [integration] `bin/task claim-next-review` must never CLAIM on an argument it did
# not understand.
#
# THE SCAR: `bin/task claim-next-review --help` — typed by an agent expecting usage
# text — printed a task slug. It had CLAIMED. bin/task hands that branch raw ARGV to
# ReviewClaimCli, which dispatched `claim-next` with an unvalidated flags hash, so the
# unrecognized flag was discarded and the atomic server pop ran anyway: a live review
# lease on a real task, a crew seat filled by a reviewer that did not exist, undone by
# hand with `bin/task review-claim release <slug>`.
#
# The CLI class's own unit coverage lives in test/lib/review_claim_cli_test.rb. This
# file pins the seam the operator actually types — the real bin/task process, its real
# dispatch — and asserts the only thing that matters: NO POP LEFT THE PROCESS. Printed
# usage text is not the property; the pre-fix CLI printed a slug and exited 0 too.
#
#   ruby -Itest test/lib/claim_next_review_flags_test.rb
# It is also picked up by the normal `bin/rails test` sweep.

require "minitest/autorun"
require "json"
require "socket"
require "open3"
require "rbconfig"
require "tmpdir"
require "fileutils"
# Neutralizes the ambient session vars AND (via OutboundSeams) pins every spelling of
# "the board" at an unroutable port for this process and every child it spawns. Both
# matter here: this file SHELLS OUT to the claim CLI, and an un-neutralized run would
# hand it the operator's live session identity.
require_relative "../support/session_env"

class ClaimNextReviewFlagsTest < Minitest::Test
  BIN = File.expand_path("../../bin/task", __dir__)
  POP_PATH = "/api/v1/tasks/claim_next_review"
  # Any well-formed session id: the CLI refuses to claim without one, so a blank
  # session would make every "nothing was claimed" assertion below true for the wrong
  # reason. The positive control proves this one really does reach the pop.
  SESSION = "3bb327a7-8676-4cf5-ce12-81804d9cb728"

  # Shells out to the REAL bin/task against a localhost stub board, and returns the
  # requests that reached it. No Rails, no network.
  #
  # ATOMIC_CAPTURE_URL IS THE LOAD-BEARING PIN. The claim CLIs do not speak
  # TASK_API_BASE at all — they go through AgentApi, which reads ATOMIC_CAPTURE_URL,
  # and requiring session_env pins THAT one unroutable for every child. Correct as a
  # floor, and a trap for a test like this: pin only TASK_API_BASE and the child talks
  # to a closed port, where "the stub saw no claim" would be just as true with the bug
  # still in place. Pointing it here makes a pop that happens a pop this test SEES.
  def run_task(args, session: SESSION)
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    requests = []
    thread = Thread.new { serve(server, requests) }

    env = SessionEnv.neutralized(
      TaskUsageSandboxEnv.child_env(sandbox_root).merge(
        "TASK_API_BASE" => "http://127.0.0.1:#{port}",
        "ATOMIC_CAPTURE_URL" => "http://127.0.0.1:#{port}",
        "AGENT_API_SECRET" => "test-secret",
        "TASK_SKIP_MARKER" => "1",
        "TASK_CLAIM_NONCE" => "inst-default",
        "TASK_REVIEW_CLAIM_SESSION" => session
      )
    )

    out, err, status = Open3.capture3(env, RbConfig.ruby, BIN, *args)
    [requests, out, err, status]
  ensure
    server&.close
    thread&.join(1)
  end

  def sandbox_root
    @sandbox_root ||= Dir.mktmpdir("claim-next-review-sandbox")
  end

  # Minimal HTTP/1.1 stub: records every request, mints a token for the auth call, and
  # answers anything else with an empty data object — which the CLI reads as an EMPTY
  # POP ("none", exit 4). Deliberate: even the positive control must not model a
  # successful claim, or it would anchor a detached renewer of its own.
  def serve(server, requests)
    loop do
      client = server.accept
      line = client.gets
      (client.close; next) if line.nil?

      method, path, = line.split(" ")
      headers = {}
      while (h = client.gets) && h != "\r\n"
        key, value = h.split(":", 2)
        headers[key.strip.downcase] = value.strip if value
      end
      body = headers["content-length"] ? client.read(headers["content-length"].to_i) : ""
      requests << { method: method, path: path, body: body }

      payload = path == "/api/v1/auth" ? JSON.generate("token" => "stub-token") : JSON.generate("data" => {})
      client.write("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n" \
                   "Content-Length: #{payload.bytesize}\r\nConnection: close\r\n\r\n#{payload}")
      client.close
    end
  rescue IOError, Errno::EBADF, Errno::ECONNRESET
    # server closed — stop serving
  end

  def pops(requests)
    requests.select { |r| r[:method] == "POST" && r[:path] == POP_PATH }
  end

  def test_help_prints_usage_and_pops_nothing
    requests, out, err, status = run_task(["claim-next-review", "--help"])

    # The pop assertion FIRST, deliberately: pre-fix, `--help` ALSO exited 0 — it
    # exited 0 having claimed. The absent pop is the only thing a regression breaks.
    assert_empty pops(requests), "a help probe must not POST the atomic pop"
    assert_empty out, "and prints no slug — stdout is what a caller captures as one"
    assert status.success?, "--help exits 0, like bin/task's own help"
    assert_match(%r{usage: bin/task review-claim}, err, "usage goes to STDERR, never stdout")
  end

  # -h is the same probe with one dash, and was the more dangerous spelling: the flag
  # parser only ever looked at "--", so a single-dash token was not even recorded as an
  # ignored key. It vanished, and the pop ran.
  def test_short_help_pops_nothing_either
    requests, out, _err, status = run_task(["claim-next-review", "-h"])

    assert_empty pops(requests), "-h must not POST the atomic pop"
    assert_empty out
    assert status.success?
  end

  def test_unknown_flag_refuses_instead_of_claiming
    requests, out, err, status = run_task(["claim-next-review", "--fast"])

    assert_empty pops(requests), "an unrecognized flag must not POST the atomic pop"
    refute status.success?, "and must exit nonzero, not claim"
    assert_empty out
    assert_match(/unrecognized argument "--fast"/, err, "the refusal NAMES the offending flag")
    assert_match(/NOTHING was claimed/, err, "and says plainly no lease was taken")
  end

  # A slug here means the caller wanted `acquire`. Popping whatever the board ranks
  # first would claim a DIFFERENT task than the one they typed.
  def test_a_stray_slug_refuses_and_names_the_command_they_meant
    requests, _out, err, status = run_task(["claim-next-review", "some-other-task"])

    assert_empty pops(requests)
    refute status.success?
    assert_match(/review-claim acquire some-other-task/, err,
                 "the refusal names the door they meant, not just the one that closed")
  end

  # THE POSITIVE CONTROL. Without it every assertion above is satisfied by a CLI that
  # refuses everything — and that failure is silent in production: a review wave that
  # claims nothing looks exactly like an empty queue. With the same env and the same
  # stub, a valid line must still reach the pop.
  def test_a_valid_invocation_still_reaches_the_pop
    requests, _out, _err, status = run_task(["claim-next-review", "--agent", "carl"])

    refute_empty pops(requests), "a valid invocation still asks the board to pop"
    assert_equal "carl", JSON.parse(pops(requests).first[:body])["reviewer"],
                 "--agent's VALUE arrived — it was not refused as a stray positional"
    assert_equal 4, status.exitstatus, "the stub's empty pop is `none` (exit 4), not a claim"
  end

  # The fail-open half of the contract, pinned here because it is what makes the
  # assertions above meaningful: a claim needs a session id, so a test that forgot one
  # would prove nothing at all.
  def test_without_a_session_id_it_fails_open_rather_than_claiming
    requests, _out, _err, status = run_task(["claim-next-review"], session: "")

    assert_empty pops(requests), "no session id ⇒ no pop"
    assert_equal 1, status.exitstatus, "fail OPEN (exit 1), never a false claim"
  end
end
