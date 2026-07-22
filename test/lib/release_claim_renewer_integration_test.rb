# frozen_string_literal: true

# [integration] the END-TO-END proof for the headless-lease guarantee on the release
# conductor claim: a REAL detached `release_claim_cli.rb renew-loop` process, a REAL
# stub board, and NO status line anywhere in the picture.
#
# The unit tests either side of this one mock the pieces — the loop is driven with
# injected lambdas (test/lib/shift_renewer_test.rb) and the spawn is recorded rather
# than performed (test/lib/release_claim_cli_test.rb). Everything they mock is exactly
# where this bug could hide again: the spawn, the detach, the env handed to the child,
# and whether that child's renew POSTs actually carry the holder's identity AND role. A
# renewer that runs but renews the WRONG instance (or the wrong role) is
# indistinguishable, from inside the mocks, from a renewer that works — and it would
# fail in the same silent way the status-line renewer did.
#
# So this test asserts the two halves of the guarantee against a live process:
#   1. a headless holder's renewals KEEP ARRIVING, unprompted, with no UI
#   2. when the anchor process dies, they STOP — a crash frees the release
#
#   ruby -Itest test/lib/release_claim_renewer_integration_test.rb

require "minitest/autorun"
require "json"
require "socket"
require "tmpdir"
require_relative "../support/session_env"

class ReleaseClaimRenewerIntegrationTest < Minitest::Test
  SESSION = "1dd549c9-9787-4de6-df23-92915da9c839"
  NONCE   = "inst-headless"
  CLI     = File.expand_path("../../bin/lib/release_claim_cli.rb", __dir__)

  # A minimal board: mints a token, records every renew it is asked for, and answers
  # 200 (still yours). Raw TCP so the test pulls in no server dependency.
  class StubBoard
    attr_reader :renews

    def initialize
      @server = TCPServer.new("127.0.0.1", 0)
      @renews = []
      @lock = Mutex.new
      @thread = Thread.new { serve }
      @thread.abort_on_exception = false
    end

    def url = "http://127.0.0.1:#{@server.addr[1]}"

    def renew_count = @lock.synchronize { @renews.length }

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
                else
                  @lock.synchronize { @renews << (JSON.parse(body) rescue {}) }
                  { "data" => { "renewed" => true } }
                end
      json = JSON.generate(payload)
      socket.print("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n" \
                   "Content-Length: #{json.bytesize}\r\nConnection: close\r\n\r\n#{json}")
    end
  end

  def setup
    @board = StubBoard.new
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

  # Wait for a condition rather than sleeping a fixed span, so the test is bounded by
  # the machine's speed and not by a guessed constant.
  def wait_until(timeout: 10, &block)
    deadline = Time.now + timeout
    sleep(0.05) until block.call || Time.now > deadline
    block.call
  end

  def test_integration_a_headless_renewer_holds_the_lease_then_frees_it_when_its_anchor_dies
    Dir.mktmpdir do |proj|
      # A stand-in for the long-lived agent process. Nothing here paints a status line;
      # this is the headless conductor the bug was about.
      @anchor = Process.spawn("sleep", "300", out: File::NULL, err: File::NULL)
      anchor_start = IO.popen(["ps", "-o", "lstart=", "-p", @anchor.to_s], &:read).to_s.strip
      refute_empty anchor_start, "the anchor's start signature is what makes pid liveness trustworthy"

      env = {
        "ATOMIC_CAPTURE_URL" => @board.url,
        "AGENT_API_SECRET" => "stub-secret",
        "CLAUDE_PROJECTS_DIR" => proj,
        "RELEASE_CONDUCTOR_CLAIM_SESSION" => SESSION,
        "TASK_CLAIM_NONCE" => NONCE,
        "RELEASE_CONDUCTOR_CLAIM_RENEW_INTERVAL" => "1"
      }
      @renewer = Process.spawn(env, RbConfig.ruby, CLI, "renew-loop", "rel-20260721-abc", "--role", "deployer",
                               "--anchor-pid", @anchor.to_s, "--anchor-start", anchor_start,
                               out: File::NULL, err: File::NULL)

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

  def alive?(pid)
    Process.waitpid(pid, Process::WNOHANG).nil? && Process.kill(0, pid).positive?
  rescue Errno::ESRCH, Errno::ECHILD
    false
  end
end
