require "test_helper"
require "socket"
require_relative "../../support/agent_message_fixtures"

# [unit] AgentMessages::DiscordGateway's guards, without a websocket: the
# decision before an IDENTIFY (our budget, then Discord's session_start_limit),
# its one receipt per stand-down, and the TLS handshake deadline. The protocol
# end to end is test/integration/discord_gateway_test.rb.
class AgentMessages::DiscordGatewayBudgetTest < ActiveSupport::TestCase
  include AgentMessageFixtures

  Gateway = AgentMessages::DiscordGateway
  Limit = AgentMessages::GatewayStartLimit::Limit

  # A budget the test sets directly.
  class FakeBudget
    attr_accessor :room, :resume_at

    def initialize(room: true, resume_at: nil)
      @room = room
      @resume_at = resume_at
    end

    def limit = 200
    def window = 24.hours
    def available?(_now) = @room
    def next_at(now) = @resume_at || now
  end

  setup do
    @log = StringIO.new
    @reads = 0
  end

  def gateway(budget: FakeBudget.new, remaining: 900, reset_after: 120, start_limit: nil)
    start_limit ||= lambda do
      @reads += 1
      Limit.new(total: 1000, remaining: remaining, reset_after: reset_after)
    end
    Gateway.new(token: "unit-token", routes: agent_routes, logger: ActiveSupport::Logger.new(@log),
                connector: ->(_url) { raise "never connects" }, lock: Object.new, budget: budget,
                start_limit: start_limit, backoff: [ 7 ])
  end

  def identify_wait(listener) = listener.send(:identify_wait)

  test "room in both budgets: IDENTIFY now" do
    assert_nil identify_wait(gateway)
    assert_equal 1, @reads
  end

  test "our budget spent: stand down until it rolls (capped to the recheck), never asking Discord" do
    budget = FakeBudget.new(room: false, resume_at: 3.hours.from_now)
    listener = gateway(budget: budget)
    wait = identify_wait(listener)

    assert_in_delta Gateway::BUDGET_RECHECK, wait, 1
    assert_equal 0, @reads, "a spent local budget costs no request"
    assert_match(/IDENTIFY budget spent \(200 in 24 hours\); standing down until/, @log.string)

    budget.resume_at = 5.seconds.from_now
    assert_in_delta 5, identify_wait(listener), 1, "a window about to roll waits only that long"
    assert_equal 1, ErrorLog.where("message LIKE ?", "%IDENTIFY budget spent%").count,
                 "one receipt per stand-down, however many rechecks"

    budget.room = true
    assert_nil identify_wait(listener)
    budget.room = false
    identify_wait(listener)
    assert_equal 2, ErrorLog.where("message LIKE ?", "%IDENTIFY budget spent%").count, "a new stand-down, a new receipt"
  end

  test "Discord's remaining below the reserve: wait out its reset_after" do
    wait = identify_wait(gateway(remaining: Gateway::START_RESERVE - 1, reset_after: 42.5))
    assert_in_delta 43.5, wait, 0.01
    assert_match(/session_start_limit has 9 of 1000 left; standing down 43s/, @log.string)
    assert ErrorLog.where("message LIKE ?", "%session_start_limit has 9 of 1000 left%").exists?

    assert_nil identify_wait(gateway(remaining: Gateway::START_RESERVE)), "at the reserve it may still IDENTIFY"
  end

  test "a start limit that cannot be read is a failed attempt: back off, never IDENTIFY blind" do
    broken = -> { raise AgentMessages::GatewayStartLimit::Error, "Discord unreachable: SocketError" }
    wait = identify_wait(gateway(start_limit: broken))
    assert_operator wait, :>, 0
    assert_operator wait, :<=, 7
    assert_match(/could not check the IDENTIFY budget \(AgentMessages::GatewayStartLimit::Error\); backing off/, @log.string)
    refute_includes @log.string, "unit-token"
  end

  test "a TLS handshake that never answers is abandoned at the deadline" do
    server = TCPServer.new("127.0.0.1", 0)
    held = []
    acceptor = Thread.new { loop { held << server.accept } }
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    assert_raises(Gateway::HandshakeTimeout) do
      Gateway.tls_connect("wss://127.0.0.1:#{server.addr[1]}/?v=10", timeout: 0.4)
    end
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    assert_operator elapsed, :<, 3, "the deadline, not a hang"
    assert Gateway::HandshakeTimeout < Timeout::Error, "connect_once treats it as a dropped connection"
  ensure
    acceptor&.kill
    held&.each(&:close)
    server&.close
  end
end
