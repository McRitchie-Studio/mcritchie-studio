require "test_helper"

# [unit] AgentMessages::GatewayIdentifyBudget: the rolling, persisted 24-hour cap
# on Discord Gateway IDENTIFYs, and AgentMessages::GatewayStartLimit, Discord's
# own count from GET /gateway/bot. Nothing reaches Discord: the transport is a
# lambda.
class AgentMessages::GatewayIdentifyBudgetTest < ActiveSupport::TestCase
  Budget = AgentMessages::GatewayIdentifyBudget

  test "the default cap sits far under Discord's 1,000 a day" do
    assert_equal 200, Budget::LIMIT
    assert_equal 24.hours, Budget::WINDOW
  end

  test "spending fills the budget; past the limit nothing is available until the oldest rolls out" do
    budget = Budget.new(limit: 3)
    start = Time.zone.parse("2026-10-14 12:00:00")
    budget.spend!(start)
    budget.spend!(start + 1.hour)
    assert budget.available?(start + 1.hour)
    budget.spend!(start + 2.hours)

    refute budget.available?(start + 2.hours)
    assert_equal 3, budget.spent(start + 2.hours)
    assert_equal start + 24.hours, budget.next_at(start + 2.hours), "the first IDENTIFY rolls out first"
    refute budget.available?(start + 24.hours - 1.second)
    assert budget.available?(start + 24.hours), "a rolling window, not a calendar day"
    assert_equal 2, budget.spent(start + 24.hours)
  end

  test "the count is persisted: a new instance (a restarted process) sees what the old one spent" do
    now = Time.current
    2.times { |i| Budget.new(limit: 2).spend!(now + i) }

    restarted = Budget.new(limit: 2)
    refute restarted.available?(now + 2), "a restart does not zero the window"
    row = AgentMessageCursor.find_by!(channel: "discord", source_ref: Budget::SOURCE_REF)
    assert_equal 2, row.cursor.split(",").size
  end

  test "spending prunes what has rolled out, so the row stays small" do
    budget = Budget.new(limit: 5)
    start = Time.current
    3.times { |i| budget.spend!(start + i) }
    budget.spend!(start + 25.hours)

    row = AgentMessageCursor.find_by!(channel: "discord", source_ref: Budget::SOURCE_REF)
    assert_equal [ (start + 25.hours).to_i ], row.cursor.split(",").map(&:to_i)
  end

  test "next_at with several past the limit waits for enough to roll out" do
    budget = Budget.new(limit: 2)
    start = Time.zone.parse("2026-10-14 00:00:00")
    3.times { |i| budget.spend!(start + i.hours) } # one over (the limit can be lowered under a full window)
    assert_equal start + 1.hour + 24.hours, budget.next_at(start + 3.hours)
  end

  # --- GET /gateway/bot ---------------------------------------------------------

  def start_limit(status: 200, body: nil)
    body ||= JSON.generate("url" => "wss://gateway.discord.gg", "shards" => 1,
                           "session_start_limit" => { "total" => 1000, "remaining" => 987, "reset_after" => 14_400_000,
                                                      "max_concurrency" => 1 })
    @calls = []
    transport = lambda do |method, url, headers, _body|
      @calls << [ method, url, headers["Authorization"] ]
      [ status, body ]
    end
    AgentMessages::GatewayStartLimit.new(token: "secret-token", transport: transport)
  end

  test "session_start_limit is read from GET /gateway/bot, reset_after in seconds" do
    limit = start_limit.call
    assert_equal [ 1000, 987, 14_400.0 ], [ limit.total, limit.remaining, limit.reset_after ]
    assert_equal [ [ :get, "https://discord.com/api/v10/gateway/bot", "Bot secret-token" ] ], @calls
  end

  test "a refused or malformed answer raises without echoing the token or the body" do
    error = assert_raises(AgentMessages::GatewayStartLimit::Error) { start_limit(status: 401, body: '{"message":"401"}').call }
    assert_equal "GET /gateway/bot answered HTTP 401", error.message
    assert_raises(AgentMessages::GatewayStartLimit::Error) { start_limit(body: "{}").call }
    assert_raises(AgentMessages::GatewayStartLimit::Error) { start_limit(body: "<html>").call }
  end
end
