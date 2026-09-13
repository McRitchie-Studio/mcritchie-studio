# frozen_string_literal: true

require "test_helper"
require "open3"
require "tmpdir"
require "socket"
require "json"
require "time"
require "rbconfig"
require "fileutils"
require "securerandom"
require Rails.root.join("lib/claim_lease").to_s

# THE BUILD CLAIM MUST OUTLIVE A HEADLESS BUILD — and must NOT outlive a dead builder.
#
# THE DEFECT, verified at source by two sessions on 2026-09-09. `lib/claim_lease.rb`
# leases the build claim for DEFAULT_TTL_SECONDS (120), and the only thing that
# renewed it was `bin/statusline`, which runs when Claude Code PAINTS A STATUS LINE.
# A headless agent shell paints nothing. So every `begin → work → ship` sequence
# longer than two minutes ran UNCLAIMED for almost all of its length, and the free
# lease was adoptable by any other session — fail-open, by design.
#
# Measured the same night: `task-prints-bare-ship-path` was claimed at 04:04, lapsed
# ~2 minutes later, was adopted by a different session, and `bin/ship` correctly
# refused nine minutes on — its builder had to `--steal` his own task back, four times
# in one sitting. `gem-wiring-ledger-stale` was found with a claim that had lapsed 8.6
# HOURS earlier while its PR sat open and green. And a cold `bin/ship` now runs ~12
# minutes BY DESIGN (gate-submit-on-green-ci waits for CI), so the DEFAULT successful
# path for every agent build is six times longer than the lease it runs under.
#
# THE FIX IS A DETACHED RENEWER, not a bigger number — the same shape the REVIEW lane
# took for the same reason (bin/lib/shift_renewer.rb, and its own end-to-end proof in
# test/lib/review_claim_renewer_integration_test.rb). The claim is renewed by a
# timer-driven process anchored to the agent process, so renewal is a property of the
# RUN rather than of the UI.
#
# WHY THIS FILE AND NOT ONLY THE UNIT TEST. test/lib/build_claim_renewer_test.rb drives
# the loop with injected lambdas, and what it mocks is exactly where this bug lived:
# whether the CLAIM SITE actually starts anything, and whether a REAL detached process
# actually renews and actually exits. A claim that renews forever and a claim that is
# never renewed again are indistinguishable from inside the mocks after one iteration.
#
# WHAT MAKES THESE TESTS BITE:
#
#   * NOTHING PAINTS A STATUS LINE ANYWHERE HERE. bin/statusline is never invoked, and
#     the child env carries no marker the status line would read. So every renewal the
#     board receives after the claim is one the RUN produced by itself — which, before
#     this change, is a thing that could not happen at all.
#   * THE ANCHOR IS HELD ALIVE across the renewal test, and its death is the separate
#     assertion. A test that let the anchor die would pass against a renewer that never
#     stops, and a test that never checked the anchor would pass against one that holds
#     a lease forever. Both halves, or the guarantee is half-proved.
#   * THE TTL IS THE ASSERTION, not a proxy for it. Each renewal writes `now + TTL`, so
#     a lease that is genuinely being carried forward ends up expiring LATER than the
#     original lease's own expiry. That inequality is exactly "the claim was driven past
#     its TTL and survived", and it is false by construction when nothing renews.
#
#   bin/rails test test/commands/build_claim_renewer_integration_test.rb
class BuildClaimRenewerIntegrationTest < ActiveSupport::TestCase
  BIN = Rails.root.join("bin/task").to_s
  # One slug per test, never a shared constant. Rails runs this file's methods in
  # PARALLEL WORKERS, and every assertion here identifies a renewer by its command line
  # (`claim-renew-loop <slug>`). With one shared slug, a test in one worker counted the
  # renewer another worker's test had started — CI read "got 2" where one was correct —
  # and a teardown's pkill could kill a sibling test's renewer mid-assertion. A slug
  # unique to the test scopes pgrep, pkill and the stub board to that test alone.
  def slug
    @slug ||= "probe-build-claim-renewal-#{SecureRandom.hex(4)}"
  end

  # The builder's live instance. Injected through the documented seams
  # (CLAUDE_CODE_SESSION_ID + SessionIdentity's TASK_CLAIM_NONCE) so the identity under
  # test is data rather than whatever process tree the suite happens to run under.
  SESSION = "019f7a4b-1c2d-77d5-8e6f-a3b4c5d6e7f8"
  NONCE   = "builder01"

  # One second, so the whole file is bounded by a few seconds of wall clock rather than
  # by the production 30s beat. The beat is a knob (ShiftRenewer.interval_from clamps
  # it); the TTL, which every assertion here is written against, is NOT touched.
  BEAT = "1"

  # A minimal, STATEFUL board: it mints a token, serves the task, and — critically —
  # applies the PATCHes it is sent, so the renewer READS BACK the very claim the move
  # wrote and can recognise the lease as its own. A board that served a fixed body
  # would make the renewer evaluate its own claim as :unclaimed and the test would pass
  # or fail for a reason that has nothing to do with renewal.
  class StubBoard
    def initialize(stage:, slug:, devops: {})
      @slug = slug
      @server = TCPServer.new("127.0.0.1", 0)
      @lock = Mutex.new
      @stage = stage
      @devops = devops
      @claims = []
      @thread = Thread.new { serve }
      @thread.abort_on_exception = false
    end

    def url = "http://127.0.0.1:#{@server.addr[1]}"

    # Every PATCH that carried a build-claim lease, oldest first. The auth POST and any
    # non-claim PATCH are excluded deliberately: counting a write that happens on every
    # run would make "no renewal arrived" unfalsifiable.
    def claims = @lock.synchronize { @claims.dup }

    def claim_count = @lock.synchronize { @claims.length }

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

      payload = request.include?("/api/v1/auth") ? { "token" => "sink-bearer" } : apply(request, body)
      json = JSON.generate(payload)
      socket.print("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n" \
                   "Content-Length: #{json.bytesize}\r\nConnection: close\r\n\r\n#{json}")
    end

    def apply(request, body)
      parsed = (JSON.parse(body) rescue {})
      @lock.synchronize do
        if request.start_with?("PATCH")
          @stage = parsed["stage"] if parsed["stage"]
          if parsed["devops"].is_a?(Hash)
            @devops = @devops.merge(parsed["devops"])
            @claims << @devops.dup if parsed["devops"]["claim_expires_at"]
          end
        end
        { "data" => { "slug" => @slug, "stage" => @stage, "title" => "Probe Build Claim Renewal",
                      "metadata" => { "devops" => @devops } } }
      end
    end
  end

  def teardown
    # Killing the ANCHOR is the deterministic stop: the renewer exits within one beat
    # once its anchor is gone, which is the very property this file asserts. The pkill
    # is belt and braces for a run cut short before the loop noticed.
    kill(@anchor)
    system("pkill", "-f", "claim-renew-loop #{slug}", out: File::NULL, err: File::NULL)
    @board&.stop
  end

  # ── THE REGRESSION ──────────────────────────────────────────────────────────

  test "[integration] a headless build claim goes on being renewed past its TTL" do
    with_desk do |desk|
      first = claim_the_task(desk)

      # THE REGRESSION, in one line: renewals arrive with NOTHING painting a status
      # line. Before the detached renewer there was exactly one write ever — the claim
      # itself — and this wait could only time out.
      assert wait_until { @board.claim_count >= 3 },
             "a headless build must go on being renewed by its own run — got " \
             "#{@board.claim_count} claim write(s), and one of those is the claim itself"

      # ...and they renew THIS instance. A renewer carrying the wrong identity would
      # post happily while the board no-opped every write, which looks identical from
      # outside.
      latest = @board.claims.last
      assert_equal SESSION, latest["claimed_session"], "the renewer must renew the HOLDER's session"
      assert_equal NONCE, latest["claim_nonce"], "and the holder's live-instance nonce"

      # THE TTL ASSERTION. Each renewal writes `now + TTL`, so a lease still being
      # carried forward expires strictly LATER than the original lease did. That is
      # "the claim was driven past its own TTL and is still held" — and it is false by
      # construction for a claim written once and never touched again.
      original = Time.parse(first["claim_expires_at"])
      assert Time.parse(latest["claim_expires_at"]) > original,
             "the lease must be carried FORWARD, not merely rewritten at the same instant"
    end
  end

  # ── AND THE OTHER HALF: IT MUST NOT OUTLIVE A DEAD BUILDER ──────────────────

  test "[integration] renewal stops when the anchor process dies" do
    with_desk do |desk|
      claim_the_task(desk)
      assert wait_until { @board.claim_count >= 2 },
             "the control: renewals must be arriving before their silence can mean anything"

      # The builder dies. Nothing else changes — no signal to the renewer, no release,
      # no stage move.
      kill(@anchor)
      @anchor = nil

      settled = wait_until_settled
      assert_equal settled, @board.claim_count,
                   "a lease that outlives a DEAD builder is worse than one that lapses too " \
                   "fast: it strands a task nobody can pick up. Renewal must stop, after " \
                   "which the ordinary #{ClaimLease::DEFAULT_TTL_SECONDS}s TTL frees the task."
    end
  end

  test "[integration] renewal stops when the task leaves building" do
    with_desk do |desk|
      claim_the_task(desk)
      assert wait_until { @board.claim_count >= 2 },
             "the control: renewals must be arriving before their silence can mean anything"

      # The task ships. That is the ONLY thing that changes.
      @board.stage = "submitted"

      settled = wait_until_settled
      assert_equal settled, @board.claim_count,
                   "a build claim on a task that is no longer building protects nothing; the " \
                   "poll that never happens is what keeps one renewer per task from becoming " \
                   "an immortal one (test/lib/review_claim_renewer_integration_test.rb)"
      assert alive?(@anchor),
             "and it stopped with its ANCHOR STILL ALIVE — an exit that needs a dead anchor " \
             "would prove nothing about this condition"
    end
  end

  # ── ONE RENEWER PER TASK, NOT PER CLAIM ─────────────────────────────────────
  #
  # MEASURED in review of ms#1356: three consecutive `move building` calls left THREE
  # live renewers and 16 lease PATCHes in ~8s. CLAUDE.md documents re-running
  # `bin/task begin <slug>` as the normal resume path, so N resumes meant N loops, each
  # polling the board every 30s for up to 12h — the accumulation the review lane paid
  # for on 2026-08-30.
  test "[integration] repeated claims by one instance leave ONE renewer" do
    with_desk do |desk|
      claim_the_task(desk)
      2.times { reclaim(desk) }

      assert wait_until { live_renewers.any? }, "the control: a renewer must be running at all"
      sleep(BEAT.to_i) # any duplicate that was going to start has started
      assert_equal 1, live_renewers.size,
                   "three claims by one instance must share one renewer — got #{live_renewers.size}"
    end
  end

  # ── A MULTI-REPO TASK'S DESK IS UNDER ANY OF ITS REPOS ──────────────────────
  #
  # build_claim_desk read only repositories.FIRST, while its sibling archive_desk_dirs
  # maps over all of them. So a task whose desk lives under its SECOND repo resolved no
  # desk — and with no desk the abandonment gate answers "unknown", which never frees a
  # claim: the renewer then ran for its whole lifetime cap on a builder it could not see.
  test "[integration] a multi-repo task's renewer finds its desk under the second repo" do
    with_desk do |_bound|
      second = File.join(@sandbox, "projects", "repo-b", ".worktrees", slug)
      FileUtils.mkdir_p(second)
      File.write(File.join(second, ".agent-context.json"), { "task_slug" => slug }.to_json)
      nowhere = Dir.mktmpdir # a cwd bound to no task, like a primary checkout

      claim_the_task(nowhere, devops: { "repositories" => %w[repo-a repo-b] })

      assert wait_until { live_renewers.any? }, "the control: a renewer must be running at all"
      assert_includes renewer_argv(live_renewers.first), "--desk #{second}",
                      "the renewer must be judged on the desk under repo-b, the only one that exists"
    ensure
      FileUtils.remove_entry(nowhere) if nowhere && File.directory?(nowhere)
    end
  end

  # ── AND IT MUST NOT LEAK OUT OF THE SUITE ───────────────────────────────────

  test "[integration] a sandboxed run starts no renewer unless it asks for one" do
    # Every test process arms TaskUsageSandbox, and the suite's other claim tests point
    # `move … building` at a THROWAWAY board. Without this default a real background
    # process is left polling an endpoint that stopped existing when the block ended —
    # which is exactly what this feature's first cut did, twice, from one unrelated
    # suite file. Default-DENY is the only version that holds: annotating the N test
    # files that claim a task misses the N+1st written next year.
    with_desk do |desk|
      claim_the_task(desk, renewer: nil)

      settled = wait_until_settled
      assert_equal settled, @board.claim_count,
                   "a sandboxed claim writes its lease and stops; the renewer is opt-IN there"
    end
  end

  private

  # Run the REAL `bin/task move <slug> building` — the build claim's acquisition site —
  # against the stub board, with a live anchor and a desk bound to this task. Returns
  # the claim the move itself wrote.
  #
  # The child env goes through BOTH sandboxes on purpose (see task_claim_gate_test.rb):
  # SessionEnv.neutralized scrubs the operator's ambient session before opting in to a
  # fake one, and TaskUsageSandboxEnv.child_env pins the usage store, transcript root
  # and HOME inside a tmpdir — the suite arms TASK_USAGE_SANDBOX process-wide, so an
  # unpinned child ABORTS before it reaches the code under test and every assertion
  # here would pass or fail for the wrong reason.
  def claim_the_task(desk, renewer: "on", devops: {})
    @board = StubBoard.new(stage: "designed", slug: slug, devops: { "kind" => "bug", "worktree_slug" => slug }.merge(devops))
    env = claim_env(desk, renewer)
    out, err, status = Open3.capture3(env, BIN, "move", slug, "building", chdir: desk)
    assert_equal 0, status.exitstatus, "the claim itself must land:\n#{out}\n#{err}"
    assert_equal 1, @board.claim_count, "the move writes exactly one claim; everything after it is renewal"
    @board.claims.first
  end

  def claim_env(desk, renewer = "on")
    env = child_env(desk).merge("TASK_API_BASE" => @board.url)
    renewer.nil? ? env.delete("TASK_BUILD_CLAIM_RENEWER") : env["TASK_BUILD_CLAIM_RENEWER"] = renewer
    env
  end

  # A second claim by the SAME live instance on a task it already holds — what a
  # resumed `bin/task begin <slug>` or a repeated `move building` does.
  def reclaim(desk)
    out, err, status = Open3.capture3(claim_env(desk), BIN, "move", slug, "building", chdir: desk)
    assert_equal 0, status.exitstatus, "a re-claim by the holder must land:\n#{out}\n#{err}"
  end

  # Live `claim-renew-loop <slug>` processes. pgrep cannot match this test process: its
  # own argv never contains the loop's subcommand.
  def live_renewers
    IO.popen(["pgrep", "-f", "claim-renew-loop #{slug}"], err: File::NULL, &:read).split.map(&:to_i)
  end

  def renewer_argv(pid)
    IO.popen(["ps", "-o", "command=", "-p", pid.to_s], err: File::NULL, &:read).to_s.strip
  end

  # A desk bound to THIS task, so the renewal is judged on evidence of work at the
  # task's own workbench — DeskActivity.desk_root refuses any directory not bound to
  # this slug, which is what keeps `--desk` from being a universal override.
  def with_desk
    Dir.mktmpdir do |desk|
      File.write(File.join(desk, ".agent-context.json"), { "task_slug" => slug }.to_json)
      @sandbox = Dir.mktmpdir
      yield desk
    ensure
      FileUtils.remove_entry(@sandbox) if @sandbox && File.directory?(@sandbox)
    end
  end

  def child_env(_desk)
    SessionEnv.neutralized(
      TaskUsageSandboxEnv.child_env(@sandbox).merge(
        "AGENT_API_SECRET" => "not-a-real-secret",
        "TASK_SKIP_MARKER" => "1",
        "CLAUDE_CODE_SESSION_ID" => SESSION,
        "TASK_CLAIM_NONCE" => NONCE,
        # The long-lived process the lease's LIFETIME answers to. Named explicitly so
        # the test owns its own anchor instead of borrowing whatever `claude` process
        # the suite happens to be running under.
        "TASK_BUILD_CLAIM_ANCHOR_PID" => anchor_pid.to_s,
        "TASK_BUILD_CLAIM_RENEW_INTERVAL" => BEAT,
        # OPTING BACK IN. Every test process arms TaskUsageSandbox, and a sandboxed
        # run does NOT start a renewer by default — otherwise the suite's other
        # claim tests would each leave a real background process polling a board
        # that stopped existing when their block ended. This file is the one that
        # means it, so it says so.
        "TASK_BUILD_CLAIM_RENEWER" => "on"
      )
    )
  end

  # A stand-in for the long-lived agent process. It stays alive for the whole of the
  # renewal test, which is what makes that test about RENEWAL rather than about the
  # anchor exit that already existed.
  def anchor_pid
    @anchor ||= Process.spawn("sleep", "120", out: File::NULL, err: File::NULL)
  end

  def kill(pid)
    return unless pid

    Process.kill("KILL", pid)
    Process.wait(pid)
  rescue StandardError
    nil
  end

  def alive?(pid)
    return false unless pid

    Process.waitpid(pid, Process::WNOHANG).nil? && Process.kill(0, pid).positive?
  rescue Errno::ESRCH, Errno::ECHILD
    false
  end

  # Wait for a condition rather than sleeping a guessed constant, so the file is
  # bounded by the machine's speed.
  def wait_until(timeout: 20)
    deadline = Time.now + timeout
    sleep(0.05) until yield || Time.now > deadline
    yield
  end

  # Let any in-flight beat land, then read the count that must not move again. Three
  # beats is long enough that a still-running loop would certainly have written.
  def wait_until_settled
    sleep(BEAT.to_i * 3)
    settled = @board.claim_count
    sleep(BEAT.to_i * 3)
    settled
  end
end
