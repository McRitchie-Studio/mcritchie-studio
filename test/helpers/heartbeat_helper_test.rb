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

  test "tokens display shows FRESH spend and excludes cache_read" do
    # A long-session turn: tiny fresh spend, huge cache_read carried only for cost.
    action = AtomicAction.new(tokens_in: 5000, tokens_out: 250, cache_read_tokens: 304_000)
    assert_equal "5.0k/250", heartbeat_tokens(action), "the cell reads fresh tokens, not the 300K+ cache read"
  end

  test "usage totals sum the fresh tokens only, never cache_read" do
    actions = [
      AtomicAction.new(tokens_in: 5000, tokens_out: 250, cache_read_tokens: 304_000, cost: 0.18, source_turn_uuid: "t1"),
      AtomicAction.new(tokens_in: 3000, tokens_out: 100, cache_read_tokens: 120_000, cost: 0.07, source_turn_uuid: "t2")
    ]
    totals = heartbeat_usage_totals(actions)

    assert_equal 8000, totals[:tokens_in], "cache_read is excluded from the displayed total"
    assert_equal 350, totals[:tokens_out]
    assert_equal 8350, totals[:tokens_total]
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

  test "[unit] category meta gives each declared span an accent, and falls back for the unknown" do
    AtomicEvent::CATEGORIES.each do |category|
      assert_match(/\A#[0-9a-f]{6}\z/, heartbeat_category_meta(category)[:accent], "#{category} needs a hex accent")
    end
    assert_equal "#8b949e", heartbeat_category_meta("Nonsense")[:accent]
  end

  test "[unit] event outcome shows the outcome_slug when closed, else the in-progress placeholder" do
    closed = AtomicEvent.new(closed_at: Time.current, outcome_slug: "found the nil-guard")
    open   = AtomicEvent.new(closed_at: nil, outcome_slug: nil)
    closed_no_outcome = AtomicEvent.new(closed_at: Time.current, outcome_slug: "")

    assert_equal "found the nil-guard", heartbeat_event_outcome(closed)
    assert_equal HeartbeatHelper::IN_PROGRESS, heartbeat_event_outcome(open)
    assert_equal HeartbeatHelper::IN_PROGRESS, heartbeat_event_outcome(closed_no_outcome)
  end

  test "[unit] time formats a stamp and dashes a blank one" do
    assert_equal "—", heartbeat_time(nil)
    assert_equal "Jun 30, 14:07", heartbeat_time(Time.zone.local(2026, 6, 30, 14, 7))
  end

  test "[unit] input preview single-lines, clips long input, and dashes blanks" do
    assert_equal "—", heartbeat_input_preview(nil)
    assert_equal "—", heartbeat_input_preview("   ")
    assert_equal "grep -rn Foo bar", heartbeat_input_preview("grep -rn\n  Foo   bar")
    long = "x" * 200
    preview = heartbeat_input_preview(long, limit: 120)
    assert_equal 121, preview.length # 120 chars + the ellipsis
    assert preview.end_with?("…")
  end

  test "[unit] token pair compacts in/out counts and dashes a span that spent nothing" do
    assert_equal "9.4k/360", heartbeat_tokens_pair(9400, 360)
    assert_equal "—", heartbeat_tokens_pair(0, 0)
    assert_equal "—", heartbeat_tokens_pair(nil, nil)
    assert_equal "1.2k/0", heartbeat_tokens_pair(1200, 0)
  end

  test "[unit] dominant returns the most frequent non-blank value, nil when all blank" do
    assert_equal "claude-opus-4-8", heartbeat_dominant(["claude-opus-4-8", "claude-opus-4-8", "claude-sonnet"])
    assert_nil heartbeat_dominant([nil, "", "  "])
    assert_nil heartbeat_dominant([])
  end

  test "[unit] event totals sum tokens + cost and pick the dominant model and mascot across a span" do
    actions = [
      AtomicAction.new(tokens_in: 9400, tokens_out: 360, cost: 0.05, model: "claude-opus-4-8", mascot: "snorlax"),
      AtomicAction.new(tokens_in: 6800, tokens_out: 2400, cost: 0.09, model: "claude-opus-4-8", mascot: "snorlax"),
      AtomicAction.new(tokens_in: 0, tokens_out: 0, cost: 0, model: nil, mascot: nil)
    ]

    totals = heartbeat_event_totals(actions)

    assert_equal 16_200, totals[:tokens_in]
    assert_equal 2_760, totals[:tokens_out]
    assert_equal 18_960, totals[:tokens_total]
    assert_in_delta 0.14, totals[:cost], 0.0001
    assert_equal "claude-opus-4-8", totals[:model]
    assert_equal "snorlax", totals[:mascot]
  end

  test "[unit] event totals over no actions are all zero / nil (a span that framed nothing)" do
    totals = heartbeat_event_totals([])

    assert_equal 0, totals[:tokens_total]
    assert_equal 0.0, totals[:cost]
    assert_nil totals[:model]
    assert_nil totals[:mascot]
  end

  test "[unit] usage totals DEDUPE by source_turn_uuid so a parallel fan-out counts a turn once" do
    # One assistant turn fired THREE parallel tool calls: three actions all carry
    # turn-A's usage. Two more actions belong to turn-B. A naive per-action sum
    # would triple-count turn-A; dedupe must count each turn once.
    actions = [
      AtomicAction.new(tokens_in: 9400, tokens_out: 360, cost: 0.05, source_turn_uuid: "turn-A"),
      AtomicAction.new(tokens_in: 9400, tokens_out: 360, cost: 0.05, source_turn_uuid: "turn-A"),
      AtomicAction.new(tokens_in: 9400, tokens_out: 360, cost: 0.05, source_turn_uuid: "turn-A"),
      AtomicAction.new(tokens_in: 6800, tokens_out: 2400, cost: 0.09, source_turn_uuid: "turn-B"),
      AtomicAction.new(tokens_in: 6800, tokens_out: 2400, cost: 0.09, source_turn_uuid: "turn-B")
    ]

    totals = heartbeat_usage_totals(actions)

    assert_equal 16_200, totals[:tokens_in],  "turn-A (9400) + turn-B (6800) counted once each"
    assert_equal 2_760,  totals[:tokens_out], "turn-A (360) + turn-B (2400) counted once each"
    assert_equal 18_960, totals[:tokens_total]
    assert_in_delta 0.14, totals[:cost], 0.0001
  end

  test "[unit] usage totals count each blank-turn action on its own (no shared turn)" do
    # Pre-usage / board / harness rows carry no source_turn_uuid — each is distinct.
    actions = [
      AtomicAction.new(tokens_in: 100, tokens_out: 10, cost: 0.01, source_turn_uuid: nil),
      AtomicAction.new(tokens_in: 200, tokens_out: 20, cost: 0.02, source_turn_uuid: nil)
    ]

    totals = heartbeat_usage_totals(actions)

    assert_equal 300, totals[:tokens_in]
    assert_equal 30,  totals[:tokens_out]
    assert_in_delta 0.03, totals[:cost], 0.0001
  end

  test "[unit] event totals inherit the turn dedupe" do
    actions = [
      AtomicAction.new(tokens_in: 5000, tokens_out: 100, cost: 0.02, model: "claude-opus-4-8", source_turn_uuid: "turn-X"),
      AtomicAction.new(tokens_in: 5000, tokens_out: 100, cost: 0.02, model: "claude-opus-4-8", source_turn_uuid: "turn-X")
    ]

    totals = heartbeat_event_totals(actions)

    assert_equal 5000, totals[:tokens_in], "the shared turn's usage is counted once"
    assert_equal 100, totals[:tokens_out]
    assert_in_delta 0.02, totals[:cost], 0.0001
    assert_equal "claude-opus-4-8", totals[:model]
  end

  test "[unit] span status badge distinguishes an open span from a closed one" do
    open_meta = heartbeat_span_status_meta(AtomicEvent.new(closed_at: nil))
    done_meta = heartbeat_span_status_meta(AtomicEvent.new(closed_at: Time.current))

    assert_equal "open", open_meta[:label]
    assert_equal "done", done_meta[:label]
    assert_not_equal open_meta[:color], done_meta[:color], "open and done must read as visibly distinct badges"
  end

  test "[unit] pretty json expands structure with 2-space indent and real newlines" do
    raw = %({"type":"text","file":{"path":"a.rb","content":"line1\\nline2"}})
    pretty = heartbeat_pretty_json(raw)

    # structure expanded across lines with a 2-space indent (not a one-liner)
    assert_operator pretty.lines.count, :>, 1, "must expand across multiple lines"
    assert_includes pretty, %(  "type": "text")
    # the escaped \n inside the content value is now a REAL line break
    assert_includes pretty, "line1\nline2"
    refute_includes pretty, "line1\\nline2", "the escaped sequence must be unescaped"
  end

  test "[unit] pretty json returns a non-JSON payload untouched and never raises" do
    assert_equal "git status --porcelain", heartbeat_pretty_json("git status --porcelain")
    assert_equal "not json: {broken", heartbeat_pretty_json("not json: {broken")
  end

  test "[unit] pretty json is blank-safe" do
    assert_equal "", heartbeat_pretty_json(nil)
    assert_equal "", heartbeat_pretty_json("")
    assert_equal "   ", heartbeat_pretty_json("   ")
  end

  # Persisted so each action carries a real id — heartbeat_shared_turn_ids keys the
  # duplicate set by action.id (the flag the row partial checks).
  def turn_action(**attrs)
    AtomicAction.create!({ session_id: "s", kind: "grep", outcome: "ok", actor: "agent",
                           occurred_at: Time.current, seq: attrs.fetch(:seq, 0) }.merge(attrs))
  end

  test "[unit] shared turn ids flag every action AFTER a turn's first, primary excluded" do
    # One assistant turn fired three parallel tool-calls (all carry turn-A's usage);
    # a fourth action is the only call of turn-B.
    first  = turn_action(seq: 0, source_turn_uuid: "turn-A")
    second = turn_action(seq: 1, source_turn_uuid: "turn-A")
    third  = turn_action(seq: 2, source_turn_uuid: "turn-A")
    solo   = turn_action(seq: 3, source_turn_uuid: "turn-B")

    dups = heartbeat_shared_turn_ids([first, second, third, solo])

    refute_includes dups, first.id, "the turn's first action is the primary, never faded"
    assert_includes dups, second.id
    assert_includes dups, third.id
    refute_includes dups, solo.id, "a turn with a single action has no duplicate"
  end

  test "[unit] blank source_turn_uuid actions are each their own primary, never shared" do
    a = turn_action(seq: 0, source_turn_uuid: nil)
    b = turn_action(seq: 1, source_turn_uuid: "")

    assert_empty heartbeat_shared_turn_ids([a, b])
  end

  test "[unit] the primary is the FIRST in the given (chronological) order" do
    early = turn_action(seq: 0, source_turn_uuid: "turn-Z")
    late  = turn_action(seq: 1, source_turn_uuid: "turn-Z")

    dups = heartbeat_shared_turn_ids([early, late])

    refute_includes dups, early.id, "the earliest action of the turn keeps its color"
    assert_includes dups, late.id
  end
end
