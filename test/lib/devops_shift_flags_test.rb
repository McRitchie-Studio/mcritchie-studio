# frozen_string_literal: true

# [integration] The REAL `bin/devops-shift` process must never touch the board on an
# argument it did not understand — and must still take, hold, and renew a real shift
# on every argument it does.
#
# The guard's logic is unit-covered in test/lib/devops_shift_argument_guard_test.rb
# with a fake API. This file pins the seam an operator (or bin/statusline, or the
# clean-up SOP) actually crosses: a real ruby process, real ARGV, real AgentApi, real
# HTTP — and asserts the only thing that matters, that NO ACQUIRE LEFT THE PROCESS.
# Printed usage text is not the property: before the guard, `acquire avi --help`
# printed a cheerful "shift acquired" and exited 0 having already POSTed.
#
# THE SECOND HALF IS WHY THIS FILE IS WORTH ITS RUNTIME. test_a_real_acquire_still…
# runs the WHOLE chain in real processes — acquire → detached renew-loop → renewals on
# the wire. The renewer re-enters this very CLI, spawned with out:/err: File::NULL, so
# a guard that refused its argv would print the refusal into /dev/null and every shift
# would lapse ~120s into a multi-minute conductor act, silently. On the release-claim
# sibling (PR #980) the mutation that stripped the spawn's anchor flags was caught by
# the real-detached-process test and by NOTHING ELSE.
#
# ATOMIC_CAPTURE_URL IS THE LOAD-BEARING PIN. This CLI does not speak TASK_API_BASE at
# all — it goes through AgentApi, which reads ATOMIC_CAPTURE_URL, and requiring
# session_env pins THAT one unroutable for every child. Correct as a floor, and a trap
# for a test like this: pin only TASK_API_BASE and the child talks to a closed port,
# where "the stub saw no acquire" would be just as true with the bug still in place.
# Pointing it at the stub is what makes an acquire that happens an acquire this test
# SEES, and the positive control is what proves the stub is genuinely being reached.
#
# NOTHING HERE TOUCHES THE PRODUCTION BOARD, and nothing here can take a real shift:
# the session identity is a fixture, and every refusal stub answers `acquired: false`.
#
#   ruby -Itest test/lib/devops_shift_flags_test.rb

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
# which is the identity a shift lease is taken UNDER.
require_relative "../support/session_env"

class DevopsShiftFlagsTest < Minitest::Test
  CLI = File.expand_path("../../bin/devops-shift", __dir__)
  ACQUIRE_PATH = "/api/v1/devops_shifts/acquire"
  RENEW_PATH = "/api/v1/devops_shifts/renew"
  # Any well-formed session id: acquire refuses without one, so a blank session would
  # make every "nothing was claimed" assertion below true for the wrong reason. The
  # positive control proves this one really does reach the board.
  SESSION = "9cc438b8-9787-4de6-df23-92915da9c839"
  NONCE = "inst-flags"

  # A minimal HTTP/1.1 board that RECORDS every request. Recording is the point: the
  # refusal assertions are all "the board was never touched", and a stub that answered
  # without recording would make them true for the wrong reason.
  class StubBoard
    def initialize(data: {})
      @server = TCPServer.new("127.0.0.1", 0)
      @data = data
      @requests = []
      @lock = Mutex.new
      @thread = Thread.new { serve }
      @thread.abort_on_exception = false
    end

    def url = "http://127.0.0.1:#{@server.addr[1]}"
    def requests = @lock.synchronize { @requests.dup }

    def stop
      @thread.kill
      @server.close
    rescue StandardError
      nil
    end

    private

    def serve
      loop do
        client = @server.accept
        handle(client)
      rescue IOError, Errno::EBADF, Errno::ECONNRESET
        break
      end
    end

    def handle(client)
      line = client.gets
      return client.close if line.nil?

      method, path, = line.split(" ")
      headers = {}
      while (h = client.gets) && h != "\r\n"
        key, value = h.split(":", 2)
        headers[key.strip.downcase] = value.strip if value
      end
      body = headers["content-length"] ? client.read(headers["content-length"].to_i) : ""
      @lock.synchronize { @requests << { method: method, path: path, body: body } }

      payload = path == "/api/v1/auth" ? { "token" => "stub-token" } : { "data" => @data }
      json = JSON.generate(payload)
      client.print("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n" \
                   "Content-Length: #{json.bytesize}\r\nConnection: close\r\n\r\n#{json}")
      client.close
    end
  end

  def setup
    @sandbox_root = Dir.mktmpdir("devops-shift-flags")
    # Answers every acquire as NOT acquired (stand down, exit 10). Deliberate: even the
    # positive control must not model a successful claim, or it would anchor a detached
    # renewer of its own. The grant-and-renew stub is built per-test below.
    @board = StubBoard.new
  end

  def teardown
    @board&.stop
    @grant_board&.stop
    kill(renewer_pid)
    kill(@anchor)
    FileUtils.remove_entry(@sandbox_root) if @sandbox_root && File.directory?(@sandbox_root)
  end

  def child_env(board, overrides = {})
    SessionEnv.neutralized(
      TaskUsageSandboxEnv.child_env(@sandbox_root).merge(
        "ATOMIC_CAPTURE_URL" => board.url,
        "TASK_API_BASE" => board.url,
        "AGENT_API_SECRET" => "stub-secret",
        "TASK_CLAIM_NONCE" => NONCE,
        "DEVOPS_SHIFT_SESSION" => SESSION
      ).merge(overrides)
    )
  end

  def run_cli(args, board: @board, env: {})
    out, err, status = Open3.capture3(child_env(board, env), RbConfig.ruby, CLI, *args)
    [board.requests, out, err, status]
  end

  def projects_dir = File.join(@sandbox_root, "projects")

  def marker(suffix)
    File.join(projects_dir, ".agents", "sessions", "#{SESSION}#{suffix}")
  end

  def renewer_pid
    File.read(marker(".devops-shift-renewer")).to_s.strip.to_i
  rescue StandardError
    nil
  end

  def kill(pid)
    return if pid.nil? || pid.to_i <= 0

    Process.kill("KILL", pid.to_i)
  rescue StandardError
    nil
  end

  def acquires(requests) = requests.select { |r| r[:method] == "POST" && r[:path] == ACQUIRE_PATH }
  def renews(requests) = requests.select { |r| r[:method] == "POST" && r[:path] == RENEW_PATH }

  def wait_until(timeout: 15)
    deadline = Time.now + timeout
    sleep(0.05) until yield || Time.now > deadline
    yield
  end

  # ── Refusal: nothing leaves the process ──────────────────────────────────────

  # THE HEADLINE REGRESSION at the real seam. `bin/devops-shift acquire avi --help` —
  # typed by an agent asking what the command does — took the avi shift.
  def test_help_after_a_lane_takes_no_shift
    requests, out, err, status = run_cli(%w[acquire avi --help])

    # The board assertion FIRST, deliberately: pre-fix this line ALSO exited 0 — it
    # exited 0 having acquired. The absent POST is the only thing a regression breaks.
    assert_empty acquires(requests), "a help probe must not POST the acquire"
    refute_path_exists marker(".devops-shift"), "nor write the held-shift marker"
    refute_path_exists marker(".devops-shift-renewer"), "nor leave a detached renewer behind"
    assert_equal 1, status.exitstatus, "a usage refusal is CANT_RUN, never a shift-state code"
    assert_match(%r{usage: bin/devops-shift acquire}, err, "usage goes to STDERR")
    refute_match(/unrecognized/, err, "a help probe is ANSWERED, not scolded as a typo")
    assert_empty out, "and never to STDOUT, where a conductor SOP reads the verdict"
  end

  def test_an_unknown_flag_refuses_without_touching_the_board
    requests, out, err, status = run_cli(["acquire", "avi", "--force"])

    assert_empty acquires(requests), "an unrecognized flag must not POST the acquire"
    refute_path_exists marker(".devops-shift")
    assert_equal 1, status.exitstatus
    assert_match(/unrecognized argument "--force"/, err, "the refusal NAMES the offending argument")
    assert_match(/NOT on shift/, err, "and says plainly what the caller is left holding")
    assert_empty out
  end

  # The more dangerous spelling: the flag parser only ever looked at "--", so a
  # single-dash token was not recorded even as an ignored key. It vanished.
  def test_a_single_dash_token_refuses_without_touching_the_board
    requests, _out, err, status = run_cli(["acquire", "avi", "-l", "Mew"])

    assert_empty acquires(requests)
    assert_equal 1, status.exitstatus
    assert_match(/unrecognized arguments "-l", "Mew"/, err)
  end

  # A refused `release` must not read as "the lane is free": the shift is still held
  # AND its detached renewer is still renewing it, so it will not even lapse.
  def test_a_refused_release_says_the_shift_is_still_held
    requests, _out, err, status = run_cli(["release", "avi", "--force"])

    assert_empty requests.select { |r| r[:path].to_s.end_with?("/release") }
    assert_equal 1, status.exitstatus
    assert_match(/STILL HELD/, err)
    refute_match(/NOTHING was claimed/, err)
  end

  # ── The positive controls: the guard is not a wall ───────────────────────────

  # Without this every assertion above is satisfied by a CLI that refuses everything —
  # and that failure is silent in production: a conductor act that takes no shift looks
  # exactly like a free lane. With the same env and the same stub, a valid line must
  # still reach the board.
  def test_a_valid_acquire_still_reaches_the_board
    requests, _out, _err, status = run_cli(%w[acquire avi])

    posted = acquires(requests)
    refute_empty posted, "a valid invocation still asks the board for the shift"
    body = JSON.parse(posted.first[:body])
    assert_equal "avi", body["lane"]
    assert_equal SESSION, body["session"], "under the caller's own live-instance identity"
    assert_equal 10, status.exitstatus, "the stub grants nothing, so this is a stand-down, not a claim"
  end

  # The optional --label must still ARRIVE. A too-eager guard reads "Mew" as a stray
  # positional and refuses the documented line.
  def test_a_valid_acquire_carries_its_label_through
    requests, _out, _err, _status = run_cli(["acquire", "alex", "--label", "Mew"])

    body = JSON.parse(acquires(requests).first[:body])
    assert_equal "alex", body["lane"], "the LANE is the target, not the label"
    assert_equal "Mew", body["label"], "--label's VALUE arrived, not refused as a positional"
  end

  def test_the_statusline_heartbeat_shape_still_renews
    requests, _out, _err, status = run_cli(%w[renew avi])

    refute_empty renews(requests), "bin/statusline's `renew <lane>` is the highest-frequency real caller"
    assert_equal 0, status.exitstatus
  end

  def test_the_bare_cross_lane_read_still_reads
    requests, out, _err, status = run_cli(%w[status])

    refute_empty requests.select { |r| r[:method] == "GET" && r[:path] == "/api/v1/devops_shifts" }
    assert_equal 0, status.exitstatus
    assert_match(/no shifts are currently held/, out)
  end

  # ── The whole chain, in real processes ───────────────────────────────────────

  # THE WALL CHECK THAT COSTS THE MOST TO GET WRONG. A real `acquire` spawns a real
  # detached `renew-loop` that RE-ENTERS this CLI's own argument guard, with its stderr
  # pinned at File::NULL. If the guard refused that line the refusal would be invisible
  # and the shift would simply stop being renewed — lapsing mid-act, letting a second
  # same-lane conductor in. So assert the renewals on the WIRE, from a process this
  # test never handed an argv to.
  def test_a_real_acquire_still_spawns_a_renewer_that_survives_the_guard_it_reenters
    @grant_board = StubBoard.new(data: { "acquired" => true, "holder" => {} })
    # A stand-in for the long-lived agent process the lease is anchored to.
    @anchor = Process.spawn("sleep", "60", out: File::NULL, err: File::NULL)

    _requests, out, _err, status = run_cli(
      %w[acquire avi],
      board: @grant_board,
      env: { "DEVOPS_SHIFT_ANCHOR_PID" => @anchor.to_s, "DEVOPS_SHIFT_RENEW_INTERVAL" => "1" }
    )

    assert_equal 0, status.exitstatus, "a granted acquire is exit 0 — you ARE on shift"
    assert_match(/shift acquired/, out)
    assert_equal "avi\n", File.read(marker(".devops-shift")), "the held-shift marker is written"
    refute_nil renewer_pid, "acquire must record the detached renewer's pid so release can stop it"

    assert wait_until { renews(@grant_board.requests).length >= 2 },
           "the renewer's own spawned line was refused by the guard it re-enters — " \
           "its stderr is /dev/null, so a lapsed shift is the only symptom"

    # And it renews THIS instance. A renewer carrying the wrong lane or identity would
    # POST happily while the board no-ops every beat — the lapse wearing a disguise.
    beat = JSON.parse(renews(@grant_board.requests).first[:body])
    assert_equal "avi", beat["lane"]
    assert_equal SESSION, beat["session"]
    assert_equal NONCE, beat["nonce"]
  ensure
    kill(renewer_pid)
    kill(@anchor)
  end
end
