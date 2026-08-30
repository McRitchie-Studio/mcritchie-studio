# frozen_string_literal: true

# [integration] the END-TO-END proof for the RELEASE CONDUCTOR renewer: a REAL detached
# `release_claim_cli.rb renew-loop` process, a REAL stub board, and NO status line
# anywhere in the picture.
#
# The unit tests either side of this one mock the pieces — the loop is driven with
# injected lambdas (test/lib/shift_renewer_test.rb) and the spawn is recorded rather
# than performed (test/lib/release_claim_cli_test.rb). Everything they mock is exactly
# where these bugs hide: the spawn, the detach, the env handed to the child, whether
# that child's renew POSTs carry the holder's identity AND role, and whether it ever
# actually stops. From inside the mocks, a renewer that runs forever and one that exits
# are indistinguishable after ONE iteration.
#
# THE THREE HALVES OF THE GUARANTEE this file asserts against a live process:
#   1. a headless holder's renewals KEEP ARRIVING, unprompted, with no UI
#   2. when the ANCHOR process dies, they STOP — a crash frees the release
#   3. when the RELEASE itself finishes, they STOP — with the anchor still alive
#
# (3) IS THE LATER FIX (/tasks/release-renewer-outlives-ship). `renew_loop` originally
# passed ShiftRenewer only `alive:`, so it terminated on its anchor dying and on NOTHING
# else. That quietly assumed a session outlives its releases; it does not. A conductor
# session runs many acts, so once a release shipped the loop kept renewing a claim over
# finished work for as long as the anchor lived — bounded only by
# ShiftRenewer::MAX_LIFETIME_SECONDS, twelve hours. It is the same shape as the
# review-lane defect fixed in /tasks/renew-loop-outlives-task, found at the same time
# and deliberately left to its own task because a production ship was running through
# this exact machinery while that PR was open.
#
# WHY THIS LANE COSTS MORE THAN THE REVIEW LANE. An orphaned review renewer wastes board
# polls. An orphaned ASSEMBLER or DEPLOYER claim additionally makes the next
# `bin/release prepare` print "🛑 assembler already held — STAND DOWN" and ABORT before
# merging or deploying anything, and it pins the fixed-path `_ship`/`_gate` workspaces
# against reclaim. A session that finished its work hours ago can wedge the ENTIRE
# qa-release lane — the exact stranding the per-release claim was designed to end,
# arriving through a different door.
#
# WHAT MAKES THE (3) TESTS BITE. They hold the ANCHOR ALIVE from start to finish and
# assert it is still alive at the moment the renewer exits. A test that kills the anchor
# passes against the pre-fix code and proves nothing whatsoever — it would just be
# re-testing (2).
#
#   ruby -Itest test/lib/release_claim_renewer_integration_test.rb

require "minitest/autorun"
require "json"
require "socket"
require "tmpdir"
require "rbconfig"
require_relative "../support/session_env"

class ReleaseClaimRenewerIntegrationTest < Minitest::Test
  SESSION = "1dd549c9-9787-4de6-df23-92915da9c839"
  NONCE   = "inst-headless"
  SLUG    = "rel-20260721-abc"
  ROLE    = "deployer"
  CLI     = File.expand_path("../../bin/lib/release_claim_cli.rb", __dir__)

  # A minimal board: mints a token, serves the release at a state the test controls, and
  # records every renew it is asked for. Raw TCP so the test pulls in no server
  # dependency.
  #
  # IT NOW ROUTES BY PATH. It used to treat every non-auth request as a renew, which was
  # correct while the loop only ever POSTed heartbeats. The loop also GETs the claim
  # status now (that is where it reads `release_state`), so a stub that counted both
  # would record an empty-bodied GET as a renewal and the identity assertions below
  # would read nil — a stub silently agreeing with whatever it was asked.
  class StubBoard
    attr_reader :renews

    def initialize(state:)
      @server = TCPServer.new("127.0.0.1", 0)
      @renews = []
      @state = state
      @lock = Mutex.new
      @thread = Thread.new { serve }
      @thread.abort_on_exception = false
    end

    def url = "http://127.0.0.1:#{@server.addr[1]}"

    def renew_count = @lock.synchronize { @renews.length }

    def state = @lock.synchronize { @state }

    # The one thing a test changes mid-flight: the release ships. Nothing else moves —
    # no signal, no teardown, no crash.
    def state=(value)
      @lock.synchronize { @state = value }
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

      # ORDER MATTERS: "/conductor_claim/renew" CONTAINS "/conductor_claim", so the renew
      # arm must be tested first or every heartbeat would be answered as a status read
      # and nothing would ever be recorded.
      payload = if request.include?("/api/v1/auth")
                  { "token" => "stub-token" }
                elsif request.include?("/conductor_claim/renew")
                  @lock.synchronize { @renews << (JSON.parse(body) rescue {}) }
                  { "data" => { "renewed" => true } }
                else
                  { "data" => { "holder" => { "live" => true }, "release_state" => state } }
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
  def wait_until(timeout: 10, &block)
    deadline = Time.now + timeout
    sleep(0.05) until block.call || Time.now > deadline
    block.call
  end

  # A stand-in for the long-lived agent process — the anchor.
  def start_anchor
    @anchor = Process.spawn("sleep", "300", out: File::NULL, err: File::NULL)
    start = IO.popen(["ps", "-o", "lstart=", "-p", @anchor.to_s], &:read).to_s.strip
    refute_empty start, "the anchor's start signature is what makes pid liveness trustworthy"
    start
  end

  def spawn_renewer(proj, anchor_start, slug: SLUG)
    env = {
      "ATOMIC_CAPTURE_URL" => @board.url,
      "AGENT_API_SECRET" => "stub-secret",
      "CLAUDE_PROJECTS_DIR" => proj,
      "RELEASE_CONDUCTOR_CLAIM_SESSION" => SESSION,
      "TASK_CLAIM_NONCE" => NONCE,
      "RELEASE_CONDUCTOR_CLAIM_RENEW_INTERVAL" => "1"
    }
    @renewer = Process.spawn(env, RbConfig.ruby, CLI, "renew-loop", slug, "--role", ROLE,
                             "--anchor-pid", @anchor.to_s, "--anchor-start", anchor_start,
                             out: File::NULL, err: File::NULL)
  end

  # ── (1) + (2): the headless-lease guarantee and the anchor exit ─────────────────

  def test_integration_a_headless_renewer_holds_the_lease_then_frees_it_when_its_anchor_dies
    Dir.mktmpdir do |proj|
      # `assembling` is a LIVE candidate: this test is about the ANCHOR, so the release
      # must never be the thing that ends the loop.
      @board = StubBoard.new(state: "assembling")

      # A stand-in for the long-lived agent process. Nothing here paints a status line;
      # this is the headless conductor the bug was about.
      anchor_start = start_anchor
      spawn_renewer(proj, anchor_start)

      # 1. THE GUARANTEE. Renewals arrive on their own, from a session with no UI.
      assert wait_until { @board.renew_count >= 3 },
             "a headless holder must go on renewing unprompted — got #{@board.renew_count} renewals"

      # And they renew THIS instance AND this ROLE. A renewer carrying the wrong nonce
      # (or the wrong role) would post happily and the board would no-op every one of
      # them, which looks identical from the outside and leaves the release free at the
      # TTL — the bug wearing a disguise. So assert the identity on the wire, not merely
      # that traffic flowed.
      posted = @board.renews.first
      assert_equal SESSION, posted["session"], "the renewer must renew the HOLDER's session"
      assert_equal NONCE, posted["nonce"], "and the holder's live-instance nonce"
      assert_equal "deployer", posted["role"], "and the ROLE it holds — a wrong-role renew no-ops silently"

      # 2. THE OTHER HALF. Kill the anchor: a crashed conductor must stop renewing so
      # its lease lapses and the release is reclaimable.
      kill(@anchor)
      @anchor = nil

      assert wait_until(timeout: 10) { !alive?(@renewer) },
             "the renewer must exit once its anchor is gone, or a crash wedges the release forever"

      settled = @board.renew_count
      sleep(2.5) # more than two renew intervals
      assert_equal settled, @board.renew_count,
                   "a dead holder renews NOTHING — this is what lets the next session take the release"
    end
  end

  # ── (3): the release exit — the loop must also die with its WORK ───────────────

  # THE REGRESSION, in its sharpest form: the release is already shipped when the loop
  # starts, so the board must never be asked for a single heartbeat.
  def test_integration_a_renewer_whose_release_already_shipped_polls_the_board_zero_times
    Dir.mktmpdir do |proj|
      @board = StubBoard.new(state: "shipped")
      anchor_start = start_anchor
      spawn_renewer(proj, anchor_start)

      assert wait_until(timeout: 15) { !alive?(@renewer) },
             "a renewer with nothing left to protect must exit on its own"
      assert alive?(@anchor),
             "and it must exit with its ANCHOR STILL ALIVE — an exit that needs a dead " \
             "anchor is behavior that already existed, and testing it proves nothing here"
      assert_equal 0, @board.renew_count,
                   "the release had already shipped: not one heartbeat was owed, and a claim " \
                   "renewed past its ship is what stands down the next bin/release prepare"
    end
  end

  # THE DISTINCTION the acceptance criterion is about: a loop that is genuinely renewing,
  # whose release then ships underneath it, must self-terminate — with no session
  # teardown, no signal and no crash anywhere in the picture.
  def test_integration_a_live_renewer_self_terminates_when_its_release_ships
    Dir.mktmpdir do |proj|
      # `assembled` on purpose: a QA-green candidate mid PRODUCTION DEPLOY, the single
      # most dangerous state to mistake for finished. The REVIEW lane calls `assembled`
      # terminal; here it must keep renewing, because that is precisely when
      # `bin/release ship` is holding this claim.
      @board = StubBoard.new(state: "assembled")
      anchor_start = start_anchor
      spawn_renewer(proj, anchor_start)

      # THE CONTROL. Renewals arrive unprompted while the deploy is live, which proves
      # the process really is running this loop against this board — so the silence
      # asserted below is a loop that STOPPED, not a loop that never started.
      assert wait_until { @board.renew_count >= 2 },
             "an assembled candidate is being SHIPPED — got #{@board.renew_count} renewals"

      # The release ships. That is the ONLY thing that changes.
      @board.state = "shipped"

      assert wait_until(timeout: 15) { !alive?(@renewer) },
             "the loop must die with its RELEASE — no teardown, no signal, no crash"
      assert alive?(@anchor),
             "the anchor never died: THIS is the exit the old anchor-only design lacked, " \
             "and a test that killed the anchor instead would pass against the original code"

      settled = @board.renew_count
      sleep(3) # three renew intervals
      assert_equal settled, @board.renew_count,
                   "and it renews nothing further — the poll that never happens is the whole fix"
    end
  end

  # FAIL OPEN, end to end. A board that never names a state is not evidence a release
  # ended, and a wrong "finished" frees a claim underneath a LIVE conductor.
  def test_integration_a_release_state_the_board_never_names_keeps_the_claim_renewed
    Dir.mktmpdir do |proj|
      # A null state is exactly what the board returns for the `__forming__` sentinel — a
      # claim held while the candidate is still being created, which is pre-assembly and
      # so the furthest thing from finished.
      @board = StubBoard.new(state: nil)
      anchor_start = start_anchor
      spawn_renewer(proj, anchor_start, slug: "__forming__")

      assert wait_until { @board.renew_count >= 2 },
             "silence is not completion: an unnamed state must keep the claim alive"
      assert alive?(@renewer),
             "a renewer that stopped here would drop the fresh-create claim during the one " \
             "window it exists to protect"
    end
  end
end
