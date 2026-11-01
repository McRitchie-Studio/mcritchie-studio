# frozen_string_literal: true

# [integration] END-TO-END proof for the RELEASE CONDUCTOR renewer: a REAL detached
# `release_claim_cli.rb renew-loop`, a REAL stub board, no status line. The unit tests
# (test/lib/shift_renewer_test.rb, test/lib/release_claim_cli_test.rb) mock where bugs hide.
#   1. a headless holder's renewals KEEP ARRIVING, unprompted, with no UI
#   2. when the ANCHOR process dies, they STOP: a crash frees the release
#   3. when the RELEASE finishes, they STOP, with the anchor still alive. Those tests must hold
#      the ANCHOR ALIVE and assert it at renewer exit; killing it just re-tests (2).
# History: task release-renewer-outlives-ship.

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

  # A minimal board: mints a token, serves the release at a state the test controls, and records
  # every renew. Raw TCP so the test pulls in no server dependency. IT ROUTES BY PATH: the loop
  # also GETs the claim status (where it reads `release_state`), so a stub counting both would
  # record an empty GET as a renewal and the identity assertions below would read nil.
  # History: task release-renewer-outlives-ship.
  class StubBoard
    attr_reader :renews

    def initialize(state:, work_remaining: false, malformed: false)
      @server = TCPServer.new("127.0.0.1", 0)
      @renews = []
      @state = state
      @work_remaining = work_remaining
      # OFF by default, deliberately: every other test in this file must keep serving
      # the exact payload it served before, or this flag would quietly rewrite their
      # premises instead of adding a case.
      @malformed = malformed
      @lock = Mutex.new
      @thread = Thread.new { serve }
      @thread.abort_on_exception = false
    end

    def url = "http://127.0.0.1:#{@server.addr[1]}"

    def renew_count = @lock.synchronize { @renews.length }

    def state = @lock.synchronize { @state }

    def work_remaining = @lock.synchronize { @work_remaining }

    def malformed = @lock.synchronize { @malformed }

    # The DEPLOYER case: a shipped release that still has member flips left. Set this
    # and the renewer must keep going even though the state reads terminal.
    def work_remaining=(value)
      @lock.synchronize { @work_remaining = value }
    end

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
                elsif malformed
                  # A 200 whose `data` is an ARRAY rather than a Hash — the realistic
                  # mistake being an index payload served where a show payload was
                  # meant. `parse_data` passes a non-Hash `data` straight through, so
                  # this is what actually reaches `release_finished?`.
                  { "data" => [{ "holder" => { "live" => true }, "release_state" => state }] }
                else
                  # BOTH HALVES, as the real endpoint serves them. `release_state`
                  # alone is not "finished" — a deployer legitimately holds a claim
                  # on a SHIPPED release while resuming member flips or finalizing a
                  # partial, and a stub that omitted work_remaining would let this
                  # suite certify a renewer that exits mid-deploy.
                  { "data" => { "holder" => { "live" => true },
                                "release_state" => state,
                                "conductor_work_remaining" => work_remaining } }
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

  # ── THE MALFORMED PAYLOAD: THE RENEWER MUST SURVIVE IT ────────────────────────
  # The live-process counterpart of the unit test in release_claim_cli_test.rb: that proves
  # `release_finished?` RETURNS false, this proves the PROCESS still stands. `ShiftRenewer.run`
  # does not rescue `finished.call`, so without `return false unless data.is_a?(Hash)` a malformed
  # 200 kills the renewer and the claim lapses at the 120s TTL, on the deployer lane letting a
  # SECOND production deploy start. The completion read precedes the first heartbeat, so a RISING
  # renew count plus a live process is the real kill signal.
  # History: task cover-renewer-payload-guard.
  def test_integration_a_malformed_status_payload_does_not_kill_the_renewer
    Dir.mktmpdir do |proj|
      # `assembling` is a LIVE candidate: the release must never be the thing that ends
      # this loop, so anything that DOES end it is the malformed payload.
      @board = StubBoard.new(state: "assembling", malformed: true)
      anchor_start = start_anchor
      spawn_renewer(proj, anchor_start)

      assert wait_until { @board.renew_count >= 3 },
             "a board answering 200 with a non-Hash `data` is not evidence the release " \
             "ended — the renewer must carry on. Got #{@board.renew_count} renewals; " \
             "unguarded, the TypeError kills the loop before the FIRST one"
      assert alive?(@renewer),
             "and the renewer PROCESS must still be standing — this is the half the unit " \
             "test cannot see, and the half the claim's survival actually depends on"
      assert alive?(@anchor),
             "with its anchor alive throughout, so a surviving loop is the payload being " \
             "tolerated and not some other exit path failing to fire"
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

  # ── THE DEPLOYER PATH: SHIPPED IS NOT FINISHED ──────────────────────────────
  # A deployer legitimately holds a claim on a `shipped` release on two paths: a `bin/release
  # ship` RE-RUN resuming member flips (`resuming_member_ship = !r.active? &&
  # unfinished.positive?`, bin/release.rb) and `bin/release finalize` on a partial finalize.
  # Stopping on state ALONE lapses the claim, where that means a CONCURRENT PRODUCTION DEPLOY. The
  # test directly above (shipped, nothing left, zero polls) passes EITHER way, which is why this
  # one has to exist.
  # History: task release-renewer-outlives-ship.
  def test_integration_a_shipped_release_with_member_work_left_keeps_renewing
    Dir.mktmpdir do |proj|
      @board = StubBoard.new(state: "shipped", work_remaining: true)
      anchor_start = start_anchor
      spawn_renewer(proj, anchor_start)

      assert wait_until(timeout: 15) { @board.renew_count >= 2 },
             "a DEPLOYER resuming member flips on a shipped release still holds a REAL " \
             "claim; exiting here lapses it mid-deploy and lets a second ship start"
      assert alive?(@renewer), "and the loop must still be running, not merely slow to exit"
    end
  end

  # The counterweight: it must STILL exit once the work is genuinely done, or the
  # fix above would have traded this bug for the original 12-hour orphan.
  def test_integration_the_renewer_exits_once_the_last_member_finishes
    Dir.mktmpdir do |proj|
      @board = StubBoard.new(state: "shipped", work_remaining: true)
      anchor_start = start_anchor
      spawn_renewer(proj, anchor_start)

      assert wait_until(timeout: 15) { @board.renew_count >= 1 }
      @board.work_remaining = false

      assert wait_until(timeout: 15) { !alive?(@renewer) },
             "terminal AND nothing left is the only combination that stops the loop"
    end
  end

end
