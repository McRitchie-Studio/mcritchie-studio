# frozen_string_literal: true

# [integration] the END-TO-END proof that a review renewer dies with its TASK, using
# a REAL detached `review-claim renew-loop` process and a REAL stub board.
#
# THE DEFECT, measured 2026-08-29 and again 2026-08-30 after it had already cost a
# full day of GitHub auth. The loop terminated on its ANCHOR SESSION dying and on
# NOTHING ELSE. That quietly assumed a session outlives its reviews; it does not. One
# long-lived session reviews many tasks, so it accumulates one immortal renewer per
# task. At 05:25Z on 2026-08-30 five were running and FOUR were renewing claims on
# work that had SHIPPED TO PRODUCTION hours earlier — anchor pid 60790 alive the whole
# time and legitimately busy. Nothing had crashed. Between them they polled the board
# roughly 14,000 times a day and spent the ACCOUNT-WIDE 1Password read budget every
# other lane shares, so the symptom presented as "1Password is down" rather than as
# anything pointing at claim renewal.
#
# WHY THIS FILE AND NOT ONLY THE UNIT TESTS. The unit tests either side drive the
# loop with injected lambdas (test/lib/shift_renewer_test.rb) and a fake API
# (test/lib/review_claim_cli_test.rb). What they mock is exactly where this bug lived
# for two days: whether a REAL detached process, spawned the way `acquire` spawns it,
# actually reads the stage and actually exits. A loop that renews forever and a loop
# that stops are indistinguishable from inside the mocks after ONE iteration.
#
# WHAT MAKES THESE TESTS BITE. Both hold the ANCHOR ALIVE from start to finish and
# assert that it is still alive at the moment the renewer exits. A test that kills the
# anchor passes against the ORIGINAL code and proves nothing whatsoever about this
# defect — that distinction is the entire point of the regression.
#
#   ruby -Itest test/lib/review_claim_renewer_integration_test.rb

require "minitest/autorun"
require "json"
require "socket"
require "tmpdir"
require "rbconfig"
require_relative "../support/session_env"

class ReviewClaimRenewerIntegrationTest < Minitest::Test
  SESSION = "b41d9c02-77aa-4f19-ae30-6b0f4d5c1e88"
  NONCE   = "inst-renew-loop"
  SLUG    = "task-that-ships"
  CLI     = File.expand_path("../../bin/lib/review_claim_cli.rb", __dir__)

  # A minimal board: mints a token, serves the task at a stage the test controls, and
  # records every renew it is asked for. Raw TCP so the test pulls in no server
  # dependency.
  class StubBoard
    attr_reader :renews

    def initialize(stage:)
      @server = TCPServer.new("127.0.0.1", 0)
      @renews = []
      @stage = stage
      @lock = Mutex.new
      @thread = Thread.new { serve }
      @thread.abort_on_exception = false
    end

    def url = "http://127.0.0.1:#{@server.addr[1]}"

    def renew_count = @lock.synchronize { @renews.length }

    def stage = @lock.synchronize { @stage }

    # The one thing the test changes mid-flight: the task ships. Nothing else moves —
    # no signal, no teardown, no crash.
    def stage=(value)
      @lock.synchronize { @stage = value }
    end

    def stop
      @thread.kill
      @server.close
    rescue StandardError
      nil
    end

    private

    def serve
      loop do
        socket = @server.accept
        handle(socket)
      rescue StandardError
        nil
      ensure
        begin
          socket&.close
        rescue StandardError
          nil
        end
      end
    end

    def handle(socket)
      request = socket.gets.to_s
      headers = {}
      while (line = socket.gets) && line.strip != ""
        key, value = line.split(":", 2)
        headers[key.to_s.strip.downcase] = value.to_s.strip
      end
      length = headers["content-length"].to_i
      body = length.positive? ? socket.read(length).to_s : ""

      payload = if request.include?("/api/v1/auth")
                  { "token" => "stub-token" }
                elsif request.include?("/review_claim/renew")
                  @lock.synchronize { @renews << (JSON.parse(body) rescue {}) }
                  { "data" => { "renewed" => true } }
                else
                  { "data" => { "slug" => SLUG, "stage" => stage } }
                end
      json = JSON.generate(payload)
      socket.print("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n" \
                   "Content-Length: #{json.bytesize}\r\nConnection: close\r\n\r\n#{json}")
    end
  end

  def teardown
    @board&.stop
    kill(@anchor)
    kill(@renewer)
  end

  def kill(pid)
    return unless pid

    Process.kill("KILL", pid)
    Process.wait(pid)
  rescue StandardError
    nil
  end

  def alive?(pid)
    Process.waitpid(pid, Process::WNOHANG).nil? && Process.kill(0, pid).positive?
  rescue Errno::ESRCH, Errno::ECHILD
    false
  end

  # Wait for a condition rather than sleeping a fixed span, so the test is bounded by
  # the machine's speed and not by a guessed constant.
  def wait_until(timeout: 15, &block)
    deadline = Time.now + timeout
    sleep(0.05) until block.call || Time.now > deadline
    block.call
  end

  # A stand-in for the long-lived agent process — the anchor. It stays alive for the
  # whole of every test here, which is what makes these assertions about the STAGE
  # exit rather than about the pre-existing anchor exit.
  def start_anchor
    @anchor = Process.spawn("sleep", "300", out: File::NULL, err: File::NULL)
    start = IO.popen(["ps", "-o", "lstart=", "-p", @anchor.to_s], &:read).to_s.strip
    refute_empty start, "the anchor's start signature is what makes pid liveness trustworthy"
    start
  end

  def spawn_renewer(proj, anchor_start)
    env = {
      "ATOMIC_CAPTURE_URL" => @board.url,
      "AGENT_API_SECRET" => "stub-secret",
      "CLAUDE_PROJECTS_DIR" => proj,
      "TASK_REVIEW_CLAIM_SESSION" => SESSION,
      "TASK_CLAIM_NONCE" => NONCE,
      "TASK_REVIEW_CLAIM_RENEW_INTERVAL" => "1"
    }
    @renewer = Process.spawn(env, RbConfig.ruby, CLI, "renew-loop", SLUG,
                             "--anchor-pid", @anchor.to_s, "--anchor-start", anchor_start,
                             out: File::NULL, err: File::NULL)
  end

  # THE REGRESSION, in its sharpest form: the work is already done when the loop
  # starts, so the board must never be asked for a single heartbeat.
  def test_integration_a_renewer_whose_task_already_shipped_polls_the_board_zero_times
    Dir.mktmpdir do |proj|
      anchor_start = start_anchor
      @board = StubBoard.new(stage: "shipped")
      spawn_renewer(proj, anchor_start)

      assert wait_until { !alive?(@renewer) },
             "a renewer with nothing left to protect must exit on its own"
      assert alive?(@anchor),
             "and it must exit with its ANCHOR STILL ALIVE — an exit that needs a dead " \
             "anchor is the behavior that already existed and that let this bug run for two days"
      assert_equal 0, @board.renew_count,
                   "the task had already shipped: not one heartbeat was owed, and heartbeats " \
                   "exactly like these drained the account-wide credential budget"
    end
  end

  # THE DISTINCTION the acceptance criterion is about: a loop that is genuinely
  # renewing, whose task then ships underneath it, must self-terminate — with no
  # session teardown, no signal and no crash anywhere in the picture.
  def test_integration_a_live_renewer_self_terminates_when_its_task_ships
    Dir.mktmpdir do |proj|
      anchor_start = start_anchor
      @board = StubBoard.new(stage: "submitted")
      spawn_renewer(proj, anchor_start)

      # THE CONTROL. Renewals arrive unprompted while the review is live, which proves
      # the process really is running this loop against this board — so the silence
      # asserted below is a loop that STOPPED, not a loop that never started.
      assert wait_until { @board.renew_count >= 2 },
             "a live review must go on being renewed — got #{@board.renew_count} renewals"

      # And they renew THIS instance. A renewer carrying the wrong identity would post
      # happily while the board no-opped every one, which looks identical from outside.
      posted = @board.renews.first
      assert_equal SESSION, posted["session"], "the renewer must renew the HOLDER's session"
      assert_equal NONCE, posted["nonce"], "and the holder's live-instance nonce"

      # The task ships. That is the ONLY thing that changes.
      @board.stage = "shipped"

      assert wait_until { !alive?(@renewer) },
             "the loop must die with its TASK — no teardown, no signal, no crash"
      assert alive?(@anchor),
             "the anchor never died: THIS is the exit the old two-condition design lacked, " \
             "and a test that killed the anchor instead would pass against the original code"

      settled = @board.renew_count
      sleep(3) # three renew intervals
      assert_equal settled, @board.renew_count,
                   "and it renews nothing further — the poll that never happens is the whole fix"
    end
  end
end
