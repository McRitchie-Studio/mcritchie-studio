require "test_helper"

# [unit] the pure label / palette / formatter helpers behind the trajectory table.
class HeartbeatHelperTest < ActionView::TestCase
  test "stage meta labels the null stage as the Session phase" do
    meta = heartbeat_stage_meta(nil)
    assert_equal "Session", meta[:label]
    assert meta[:description].present?
    assert meta[:accent].present?
  end

  test "stage meta titleizes an unknown stage with a fallback accent" do
    meta = heartbeat_stage_meta("mystery")
    assert_equal "Mystery", meta[:label]
    assert meta[:accent].present?
  end

  test "actor description maps the known lanes" do
    assert_match(/session agent/i, heartbeat_actor_description("agent"))
    assert_equal "Rails board / bin command", heartbeat_actor_description("board")
    assert_equal "Claude Code / Codex runtime", heartbeat_actor_description("harness")
  end

  test "model short drops the claude vendor prefix and a tier suffix" do
    assert_equal "opus-4-8", heartbeat_model_short("claude-opus-4-8")
    assert_equal "opus-4-8", heartbeat_model_short("claude-opus-4-8[1m]")
    assert_equal "—", heartbeat_model_short(nil)
  end

  test "tokens compact abbreviates thousands" do
    assert_equal "360", heartbeat_tokens_compact(360)
    assert_equal "9.4k", heartbeat_tokens_compact(9400)
  end

  test "tokens pair dashes a usageless action and renders in/out otherwise" do
    quiet = AtomicAction.new(tokens_in: 0, tokens_out: 0)
    busy  = AtomicAction.new(tokens_in: 9400, tokens_out: 360)
    assert_equal "—", heartbeat_tokens(quiet)
    assert_equal "9.4k/360", heartbeat_tokens(busy)
  end

  test "cost formats by magnitude and dashes a zero cost" do
    assert_equal "—", heartbeat_cost(0)
    assert_equal "$0.00", heartbeat_cost(0.0005)
    assert_equal "$0.0090", heartbeat_cost(0.009)
    assert_equal "$5.40", heartbeat_cost(5.4)
  end

  test "outcome meta colors ok green, error red, pending grey" do
    assert_equal "#3fb950", heartbeat_outcome_meta("ok")[:color]
    assert_equal "#f85149", heartbeat_outcome_meta("error")[:color]
    assert_equal "#6e7681", heartbeat_outcome_meta("pending")[:color]
  end
end
