# frozen_string_literal: true

# [integration] bin/content's SESSION — the string that is the entire proof of a
# content claim, driven through the real script against a stub board.
#
# THE DEFECT (found at PR 1498's review, verified 2026-09-22). The id was derived
# from `tmp/content-session` — ONE FILE PER CHECKOUT — while
# docs/agents/agents/turf_monster/sops/content-build.md sends every soul to the
# hub primary. Two souls therefore presented the SAME string, so the server's
# write guard — which is correct, and which refuses the moment two sessions differ
# — could not tell them apart, and the sequence the lease exists to prevent went
# through. The guard was never the problem; what it authenticated was.
#
# The board is a local HTTP stub that RECORDS the session each claim carries, so
# these assert on the wire rather than on the script's own reporting.
#
#   ruby -Itest test/lib/content_cli_test.rb
# Also picked up by the normal `bin/rails test` sweep.

require "minitest/autorun"
require "open3"
require "json"
require "socket"
require "rbconfig"
require "fileutils"

class ContentCliTest < Minitest::Test
  BIN  = File.expand_path("../../bin/content", __dir__)
  ROOT = File.expand_path("../..", __dir__)

  # The per-agent-process session files this script derives. Namespaced so a run
  # here can never collide with a real one sitting in the same checkout.
  NONCE_A = "contentclitest-a"
  NONCE_B = "contentclitest-b"

  def teardown
    [NONCE_A, NONCE_B, "shared"].each do |name|
      path = File.join(ROOT, "tmp", "content-sessions", name)
      File.delete(path) if name != "shared" && File.file?(path)
    end
  end

  # --- stub board ------------------------------------------------------------

  # Answers /auth and /contents/claim_next, appending every claim's `session` to
  # +seen+ so the test reads what actually crossed the wire.
  def with_board(reason: "claimed", seen: [])
    server = TCPServer.new("127.0.0.1", 0)
    thread = Thread.new { serve(server, reason, seen) }
    yield server.addr[1]
  ensure
    server&.close
    thread&.kill
  end

  def serve(server, reason, seen)
    loop do
      client = server.accept
      request = client.gets
      (client.close; next) if request.nil?

      length = 0
      while (header = client.gets) && header.strip != ""
        length = header.split(":", 2).last.to_i if header.downcase.start_with?("content-length:")
      end
      body = length.positive? ? client.read(length).to_s : ""
      path = request.split(" ")[1].to_s

      payload =
        if path.start_with?("/api/v1/auth")
          { "data" => { "token" => "stub-token" } }
        else
          seen << (JSON.parse(body)["session"] rescue nil)
          claimed = reason == "claimed" ? card : nil
          { "data" => { "claimed" => claimed, "reason" => reason } }
        end.to_json

      client.print("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n" \
                   "Content-Length: #{payload.bytesize}\r\nConnection: close\r\n\r\n#{payload}")
      client.close
    end
  rescue StandardError
    nil
  end

  def card
    { "slug" => "bills-beat-dolphins", "stage" => "idea", "title" => "Bills Beat Dolphins",
      "workflow" => "game_recap", "claimed_by" => "turf-monster" }
  end

  def run_claim(port, env = {})
    base = { "CONTENT_API_BASE" => "http://127.0.0.1:#{port}",
             "AGENT_API_SECRET" => "stub-secret",
             "CONTENT_SESSION" => nil,
             "TASK_CLAIM_NONCE" => nil }
    Open3.capture3(base.merge(env), RbConfig.ruby, BIN, "claim", "--agent", "turf-monster")
  end

  # --- the criterion: two souls on one checkout get distinct sessions -------

  def test_two_agent_processes_on_one_checkout_claim_with_different_sessions
    seen = []
    with_board(seen: seen) do |port|
      run_claim(port, "TASK_CLAIM_NONCE" => NONCE_A)
      run_claim(port, "TASK_CLAIM_NONCE" => NONCE_B)
    end

    assert_equal 2, seen.compact.size, "both claims must have reached the board"
    refute_equal seen[0], seen[1],
                 "one checkout, two agent processes, ONE session string - this is the bug"
  end

  # THE OTHER HALF, and the property the old single-file design got RIGHT: a claim
  # and its release are separate processes, so one soul's id must not change
  # between invocations. A fix that made every call unique would trade this bug
  # for "your own release looks like a stranger's".
  def test_one_agent_process_claims_with_the_same_session_twice
    seen = []
    with_board(seen: seen) do |port|
      run_claim(port, "TASK_CLAIM_NONCE" => NONCE_A)
      run_claim(port, "TASK_CLAIM_NONCE" => NONCE_A)
    end

    assert_equal 2, seen.compact.size
    assert_equal seen[0], seen[1], "the same agent process must pair its claim and release"
  end

  def test_an_explicit_content_session_wins_and_draws_no_caveat
    seen = []
    err = status = nil
    with_board(seen: seen) do |port|
      _out, err, status = run_claim(port, "CONTENT_SESSION" => "content-turf-monster-42",
                                    "TASK_CLAIM_NONCE" => NONCE_A)
    end

    assert_predicate status, :success?
    assert_equal "content-turf-monster-42", seen.first
    refute_match(/export CONTENT_SESSION/, err,
                 "a soul that already named its session must not be told to name one")
  end

  def test_a_derived_session_says_what_it_does_not_separate
    err = nil
    with_board do |port|
      _out, err, = run_claim(port, "TASK_CLAIM_NONCE" => NONCE_A)
    end

    assert_match(/SUBAGENTS/, err)
    assert_match(/CONTENT_SESSION/, err)
  end

  # --- a session-less claim is a caller error, not an empty queue -----------
  #
  # The endpoint answers 200 by contract, so the refusal rides in `reason`. Read
  # as an empty queue it printed "nothing to claim (session_required)" and exited
  # 0 — a refusal wearing the costume of a normal outcome.
  def test_a_session_required_refusal_is_not_read_as_an_empty_queue
    out = err = status = nil
    with_board(reason: "session_required") do |port|
      out, err, status = run_claim(port, "TASK_CLAIM_NONCE" => NONCE_A)
    end

    refute_predicate status, :success?
    refute_match(/nothing to claim/, err)
    assert_match(/no session was sent/, err)
    assert_match(/CONTENT_SESSION/, err)
    assert_empty out.strip
  end

  # An empty queue IS still a normal outcome — the fix above must not have made
  # every non-claim an error.
  def test_an_empty_queue_is_still_a_normal_outcome
    err = status = nil
    with_board(reason: "none_claimable") do |port|
      _out, err, status = run_claim(port, "TASK_CLAIM_NONCE" => NONCE_A)
    end

    assert_predicate status, :success?
    assert_match(/nothing to claim/, err)
  end
end
