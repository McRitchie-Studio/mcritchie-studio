# frozen_string_literal: true

# [integration] The REAL `bin/lib/release_claim_cli.rb` process must never touch the
# board on an argument it did not understand.
#
# The class's guard logic is unit-covered in test/lib/release_claim_argument_guard_test.rb
# with a fake API. This file pins the seam an operator (or bin/release) actually crosses:
# a real ruby process, real ARGV, real AgentApi, real HTTP — and asserts the only thing
# that matters, that NO CLAIM REQUEST LEFT THE PROCESS. Printed usage text is not the
# property: before the guard, a line with an unknown flag printed a stand-down message
# and exited 10 having already POSTed.
#
# ATOMIC_CAPTURE_URL IS THE LOAD-BEARING PIN, and the sibling PR's first integration
# test passed for the wrong reason without it. The claim CLIs do not speak TASK_API_BASE
# at all — they go through AgentApi, which reads ATOMIC_CAPTURE_URL. Pin only
# TASK_API_BASE and the child talks to a closed port, where "the stub saw no claim"
# is just as true with the bug still in place. Pointing it at the stub is what makes a
# request that happens a request this test SEES, and the positive control is what
# proves the stub is genuinely being reached.
#
# NOTHING HERE TOUCHES THE PRODUCTION BOARD. Taking a real conductor lease is precisely
# the defect under test; the stub answers every claim as NOT acquired, so no code path
# below can anchor a detached renewer.
#
#   ruby -Itest test/lib/release_claim_flags_test.rb

require "minitest/autorun"
require "json"
require "socket"
require "open3"
require "rbconfig"
require "tmpdir"
require "fileutils"
# Neutralizes the ambient session vars AND pins every spelling of "the board" at an
# unroutable port for this process and every child. Both matter: this file SHELLS OUT,
# and an un-neutralized run would hand the CLI the operator's live session identity —
# which is the identity a conductor claim is taken UNDER.
require_relative "../support/session_env"

class ReleaseClaimFlagsTest < Minitest::Test
  CLI = File.expand_path("../../bin/lib/release_claim_cli.rb", __dir__)
  SLUG = "rel-20260721-abc123"
  CLAIM_PATH = "/api/v1/releases/#{SLUG}/conductor_claim"
  LIVE_PATH = "/api/v1/release_conductor_claims/live"
  # Any well-formed session id: acquire refuses without one, so a blank session would
  # make every "nothing was claimed" assertion below true for the wrong reason. The
  # positive control proves this one really does reach the board.
  SESSION = "7cc218a6-8676-4cf5-ce12-81804d9cb728"

  # Shells out to the REAL CLI against a localhost stub board and returns the requests
  # that reached it. No Rails, no network, no production board.
  def run_cli(args, session: SESSION)
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    requests = []
    thread = Thread.new { serve(server, requests) }

    env = SessionEnv.neutralized(
      TaskUsageSandboxEnv.child_env(sandbox_root).merge(
        "ATOMIC_CAPTURE_URL" => "http://127.0.0.1:#{port}",
        "TASK_API_BASE" => "http://127.0.0.1:#{port}",
        "AGENT_API_SECRET" => "test-secret",
        "TASK_CLAIM_NONCE" => "inst-default",
        "RELEASE_CONDUCTOR_CLAIM_SESSION" => session
      )
    )

    out, err, status = Open3.capture3(env, RbConfig.ruby, CLI, *args)
    [requests, out, err, status]
  ensure
    server&.close
    thread&.join(1)
  end

  def sandbox_root
    @sandbox_root ||= Dir.mktmpdir("release-claim-flags-sandbox")
  end

  def teardown
    FileUtils.remove_entry(@sandbox_root) if @sandbox_root && File.directory?(@sandbox_root)
  end

  # Minimal HTTP/1.1 stub: records every request, mints a token for the auth call, and
  # answers everything else with an empty data object — which the CLI reads as NOT
  # ACQUIRED (stand down, exit 10). Deliberate: even the positive control must not
  # model a successful claim, or it would anchor a detached renewer of its own.
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

  def claims(requests)
    requests.select { |r| r[:path].to_s.start_with?(CLAIM_PATH) }
  end

  # ── Refusal: nothing leaves the process ──────────────────────────────────────

  def test_an_unknown_flag_refuses_without_touching_the_board
    requests, out, err, status = run_cli(["acquire", SLUG, "--role", "deployer", "--force"])

    # The board assertion FIRST, deliberately. Pre-fix this line ALSO printed a
    # plausible message and exited nonzero — it exited nonzero having already POSTed.
    assert_empty claims(requests), "an unrecognized flag must not POST a conductor claim"
    assert_equal 1, status.exitstatus, "a usage refusal is CANT_RUN, not a claim-state code"
    assert_match(/unrecognized argument "--force"/, err, "the refusal NAMES the offending argument")
    assert_match(/NOTHING was claimed/, err)
    assert_empty out, "usage and refusals go to STDERR"
  end

  # The more dangerous spelling: the flag parser only ever looked at "--", so a
  # single-dash token was not recorded even as an ignored key. It vanished.
  def test_a_single_dash_token_refuses_without_touching_the_board
    requests, _out, err, status = run_cli(["acquire", SLUG, "-r", "deployer"])

    assert_empty claims(requests)
    assert_equal 1, status.exitstatus
    assert_match(/unrecognized arguments "-r", "deployer"/, err)
  end

  def test_help_prints_usage_and_claims_nothing
    requests, out, err, status = run_cli(["acquire", SLUG, "--role", "deployer", "--help"])

    assert_empty claims(requests), "a help probe must not POST a conductor claim"
    assert_match(%r{usage: release-claim acquire}, err, "usage goes to STDERR")
    assert_empty out
    assert_equal 1, status.exitstatus,
                 "0 here would tell bin/release it holds a lease it does not hold"
  end

  def test_short_help_claims_nothing_either
    requests, _out, err, status = run_cli(["-h"])

    assert_empty claims(requests)
    assert_match(%r{usage: release-claim acquire}, err)
    assert_equal 1, status.exitstatus
  end

  # A refused `release` is the dangerous-direction case: the claim is STILL HELD and
  # its detached renewer is still renewing, so it does not even lapse. "NOTHING was
  # claimed" would send an operator away from a lane that is still locked.
  def test_a_refused_release_reports_the_claim_is_still_held
    requests, _out, err, status = run_cli(["release", SLUG, "--role", "deployer", "--force"])

    assert_empty claims(requests), "a refused release must not POST either"
    assert_equal 1, status.exitstatus
    assert_match(/STILL HELD/, err)
    refute_match(/NOTHING was claimed/, err, "a refused release failed to RELEASE, not to claim")
  end

  # ── THE POSITIVE CONTROL ─────────────────────────────────────────────────────

  # Without this, every assertion above is satisfied by a CLI that refuses everything —
  # and by a test whose stub was never reachable in the first place. Both failures are
  # silent in production: a release that claims nothing looks exactly like a release
  # nobody is running, right up until two conductors assemble the same one.
  def test_a_valid_acquire_still_reaches_the_board_with_its_flag_values
    requests, _out, _err, status = run_cli(["acquire", SLUG, "--role", "deployer", "--label", "Snorlax"])

    posted = claims(requests)
    refute_empty posted, "a valid invocation still asks the board for the claim"
    body = JSON.parse(posted.first[:body])
    assert_equal "deployer", body["role"], "--role's VALUE arrived — not refused as a stray positional"
    assert_equal "Snorlax", body["label"], "--label's VALUE arrived intact"
    assert_equal SESSION, body["session"], "and the claim is taken under the session we pinned"
    assert_equal 10, status.exitstatus, "the stub answers NOT acquired ⇒ stand down (10), never a real lease"
  end

  # The reclaim guard's read is the third real caller and takes no slug, so it exercises
  # the branch where a stray positional would otherwise be swallowed.
  def test_the_reclaim_guards_any_live_read_still_reaches_the_board
    requests, _out, _err, status = run_cli(["any-live", "--role", "assembler"])

    live = requests.select { |r| r[:path].to_s.start_with?(LIVE_PATH) }
    refute_empty live, "any-live still queries the cross-release liveness endpoint"
    assert_match(/role=assembler/, live.first[:path], "--role's VALUE arrived in the query")
    assert_equal 3, status.exitstatus, "the stub reports no live claim ⇒ NOT_LIVE (3), free to reclaim"
  end

  # The fail-open half of the contract, pinned here because it is what makes the
  # refusal assertions meaningful: a claim needs a session id, so a test that forgot
  # one would prove nothing at all.
  def test_without_a_session_id_it_fails_open_rather_than_claiming
    requests, _out, _err, status = run_cli(["acquire", SLUG, "--role", "deployer"], session: "")

    assert_empty claims(requests), "no session id ⇒ no claim POST"
    assert_equal 1, status.exitstatus, "fail OPEN (exit 1), never a false claim"
  end
end
