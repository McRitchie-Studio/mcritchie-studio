require "test_helper"

# [unit] the pure label / palette / formatter helpers behind the trajectory table.
class HeartbeatHelperTest < ActionView::TestCase
  # The stage-change badge reuses the board palette (stage_scheme + STAGE_LABELS),
  # so the helper calls across into ApplicationHelper — make it available directly.
  include ApplicationHelper
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

  test "release scope meta derives phase/tier/host for a registered scope key" do
    meta = heartbeat_release_scope_meta("ship_test_gate")
    assert_equal "ship", meta["phase"]
    assert_equal "full", meta["tier"]
    assert_equal "local", meta["host"]
  end

  test "release scope meta is an empty hash for an unregistered scope key" do
    assert_equal({}, heartbeat_release_scope_meta("no_such_scope"))
    assert_equal({}, heartbeat_release_scope_meta(nil))
  end

  test "test scope counts re-parses minitest, playwright, and http shapes from the summary" do
    assert_equal "141 runs, 320 assertions, 0 failures, 0 errors",
                 heartbeat_test_scope_counts("… · pass · 141 runs, 320 assertions, 0 failures, 0 errors · 1.2s · x")
    assert_equal "12 passed, 2 failed", heartbeat_test_scope_counts("… · fail · 12 passed, 2 failed · 3s")
    assert_equal "http 200", heartbeat_test_scope_counts("… · pass · http 200 · 0.4s")
    assert_nil heartbeat_test_scope_counts("… · pass · nothing recognizable here")
    assert_nil heartbeat_test_scope_counts(nil)
  end

  test "duration renders sub-second in ms and longer in seconds, nil when unmeasured" do
    assert_equal "830ms", heartbeat_duration(830)
    assert_equal "1.2s", heartbeat_duration(1200)
    assert_nil heartbeat_duration(0)
    assert_nil heartbeat_duration(nil)
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
    quiet = AgentAction.new(tokens_in: 0, tokens_out: 0)
    busy  = AgentAction.new(tokens_in: 9400, tokens_out: 360)
    assert_equal "—", heartbeat_tokens(quiet)
    assert_equal "9.4k/360", heartbeat_tokens(busy)
  end

  test "tokens display shows FRESH spend and excludes cache_read" do
    # A long-session turn: tiny fresh spend, huge cache_read carried only for cost.
    action = AgentAction.new(tokens_in: 5000, tokens_out: 250, cache_read_tokens: 304_000)
    assert_equal "5.0k/250", heartbeat_tokens(action), "the cell reads fresh tokens, not the 300K+ cache read"
  end

  test "usage totals sum the fresh tokens only, never cache_read" do
    actions = [
      AgentAction.new(tokens_in: 5000, tokens_out: 250, cache_read_tokens: 304_000, cost: 0.18, source_turn_uuid: "t1"),
      AgentAction.new(tokens_in: 3000, tokens_out: 100, cache_read_tokens: 120_000, cost: 0.07, source_turn_uuid: "t2")
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
    AgentActivity::CATEGORIES.each do |category|
      assert_match(/\A#[0-9a-f]{6}\z/, heartbeat_category_meta(category)[:accent], "#{category} needs a hex accent")
    end
    assert_equal "#8b949e", heartbeat_category_meta("Nonsense")[:accent]
  end

  test "[unit] event outcome shows the outcome_slug when closed, else the in-progress placeholder" do
    closed = AgentActivity.new(closed_at: Time.current, outcome_slug: "found the nil-guard")
    open   = AgentActivity.new(closed_at: nil, outcome_slug: nil)
    closed_no_outcome = AgentActivity.new(closed_at: Time.current, outcome_slug: "")

    assert_equal "found the nil-guard", heartbeat_activity_result(closed)
    assert_equal HeartbeatHelper::IN_PROGRESS, heartbeat_activity_result(open)
    assert_equal HeartbeatHelper::IN_PROGRESS, heartbeat_activity_result(closed_no_outcome)
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
      AgentAction.new(tokens_in: 9400, tokens_out: 360, cost: 0.05, model: "claude-opus-4-8", mascot: "snorlax"),
      AgentAction.new(tokens_in: 6800, tokens_out: 2400, cost: 0.09, model: "claude-opus-4-8", mascot: "snorlax"),
      AgentAction.new(tokens_in: 0, tokens_out: 0, cost: 0, model: nil, mascot: nil)
    ]

    totals = heartbeat_activity_totals(actions)

    assert_equal 16_200, totals[:tokens_in]
    assert_equal 2_760, totals[:tokens_out]
    assert_equal 18_960, totals[:tokens_total]
    assert_in_delta 0.14, totals[:cost], 0.0001
    assert_equal "claude-opus-4-8", totals[:model]
    assert_equal "snorlax", totals[:mascot]
  end

  test "[unit] event totals over no actions are all zero / nil (a span that framed nothing)" do
    totals = heartbeat_activity_totals([])

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
      AgentAction.new(tokens_in: 9400, tokens_out: 360, cost: 0.05, source_turn_uuid: "turn-A"),
      AgentAction.new(tokens_in: 9400, tokens_out: 360, cost: 0.05, source_turn_uuid: "turn-A"),
      AgentAction.new(tokens_in: 9400, tokens_out: 360, cost: 0.05, source_turn_uuid: "turn-A"),
      AgentAction.new(tokens_in: 6800, tokens_out: 2400, cost: 0.09, source_turn_uuid: "turn-B"),
      AgentAction.new(tokens_in: 6800, tokens_out: 2400, cost: 0.09, source_turn_uuid: "turn-B")
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
      AgentAction.new(tokens_in: 100, tokens_out: 10, cost: 0.01, source_turn_uuid: nil),
      AgentAction.new(tokens_in: 200, tokens_out: 20, cost: 0.02, source_turn_uuid: nil)
    ]

    totals = heartbeat_usage_totals(actions)

    assert_equal 300, totals[:tokens_in]
    assert_equal 30,  totals[:tokens_out]
    assert_in_delta 0.03, totals[:cost], 0.0001
  end

  test "[unit] event totals inherit the turn dedupe" do
    actions = [
      AgentAction.new(tokens_in: 5000, tokens_out: 100, cost: 0.02, model: "claude-opus-4-8", source_turn_uuid: "turn-X"),
      AgentAction.new(tokens_in: 5000, tokens_out: 100, cost: 0.02, model: "claude-opus-4-8", source_turn_uuid: "turn-X")
    ]

    totals = heartbeat_activity_totals(actions)

    assert_equal 5000, totals[:tokens_in], "the shared turn's usage is counted once"
    assert_equal 100, totals[:tokens_out]
    assert_in_delta 0.02, totals[:cost], 0.0001
    assert_equal "claude-opus-4-8", totals[:model]
  end

  test "[unit] span status badge distinguishes an open span from a closed one" do
    open_meta = heartbeat_activity_status_meta(AgentActivity.new(closed_at: nil))
    done_meta = heartbeat_activity_status_meta(AgentActivity.new(closed_at: Time.current))

    assert_equal "open", open_meta[:label]
    assert_equal "done", done_meta[:label]
    assert_not_equal open_meta[:color], done_meta[:color], "open and done must read as visibly distinct badges"
  end

  test "[unit] a span whose task transitioned in-window badges as the target stage" do
    slug  = "stage-change-status-badge"
    event = AgentActivity.new(task_slug: slug, opened_at: 3.minutes.ago, closed_at: 1.minute.ago)
    te    = TaskEvent.new(task_slug: slug, to_stage: "submitted", kind: "transition", occurred_at: 2.minutes.ago)

    meta = heartbeat_activity_status_meta(event, { slug => [te] })

    assert_equal "submitted", meta[:stage]
    assert_equal "Submitted", meta[:label], "stage badge label reuses Task::STAGE_LABELS"
    assert_equal stage_scheme("submitted"), meta[:scheme], "stage badge color reuses the board's stage_scheme"
  end

  test "[unit] the LAST in-window transition wins the stage badge" do
    slug   = "multi-move"
    event  = AgentActivity.new(task_slug: slug, opened_at: 5.minutes.ago, closed_at: Time.current)
    first  = TaskEvent.new(task_slug: slug, to_stage: "submitted", kind: "transition", occurred_at: 4.minutes.ago)
    second = TaskEvent.new(task_slug: slug, to_stage: "reviewed",  kind: "transition", occurred_at: 1.minute.ago)

    meta = heartbeat_activity_status_meta(event, { slug => [first, second] })
    assert_equal "reviewed", meta[:stage]
  end

  test "[unit] a transition outside the span window falls back to the done badge" do
    slug   = "outside-window"
    event  = AgentActivity.new(task_slug: slug, opened_at: 2.minutes.ago, closed_at: 1.minute.ago)
    before = TaskEvent.new(task_slug: slug, to_stage: "submitted", kind: "transition", occurred_at: 5.minutes.ago)

    meta = heartbeat_activity_status_meta(event, { slug => [before] })
    assert_equal "done", meta[:label]
    assert_nil meta[:stage]
  end

  test "[unit] a span with no task_slug ignores transitions and stays open/done" do
    event = AgentActivity.new(task_slug: nil, opened_at: 2.minutes.ago, closed_at: 1.minute.ago)
    other = TaskEvent.new(task_slug: "other", to_stage: "submitted", kind: "transition", occurred_at: 90.seconds.ago)

    meta = heartbeat_activity_status_meta(event, { "other" => [other] })
    assert_equal "done", meta[:label]
    assert_nil meta[:stage]
  end

  test "[unit] status meta with no transitions map still returns the plain open/done badge" do
    assert_equal "open", heartbeat_activity_status_meta(AgentActivity.new(closed_at: nil, opened_at: Time.current))[:label]
    assert_equal "done", heartbeat_activity_status_meta(AgentActivity.new(closed_at: Time.current, opened_at: Time.current))[:label]
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

  # ---- the compact Agent cell (acting soul over the base mascot) ----
  # The cell is a flex row: an OVERLAPPING avatar column (.hb-avatars) with the acting
  # SOUL face (.hb-soulava, ON TOP) over the base session mascot (.hb-mascotava, beneath),
  # plus a NAME column (.hb-names) — the PRIMARY name (.hb-nameprimary: the soul, else the
  # solo mascot) over the subordinate mascot name (.hb-namesub, only when a soul is present).
  # Faces reuse the shared components/agent_avatar primitive; unseeded here (no sprite_url),
  # so each face is its deterministic initials bubble. Assertions key off the data-test
  # hooks, the visible names in the side column, and the avatar circle.

  test "[unit] agent cell stacks the acting soul avatar ON TOP of the base mascot, names in a side column" do
    avi  = Agent.new(slug: "avi", name: "Avi", metadata: { "emoji" => "📋", "color" => "#FB7185" })
    poke = Pokemon.new(slug: "shellder", name: "Shellder")
    html = heartbeat_agent_cell(mascot_slug: "shellder", pokemon: poke, agent_slug: "avi", agent: avi)
    frag = Nokogiri::HTML::DocumentFragment.parse(html)

    # a stack wrapper holding an overlapping avatar column + a side name column
    assert frag.at_css(".hb-agentstack[data-test=agent-stack]"), "expected a stacked cell"
    assert_nil frag.at_css(".hb-agentstack.hb-solo"), "a cell WITH a soul is not solo"
    # the acting soul avatar rides ON TOP (its own tint ring); the base mascot beneath, dimmed
    soul = frag.at_css(".hb-ava.hb-soulava[data-test=agent-soul]")
    assert_equal "avi", soul["data-soul"]
    assert soul.at_css(".rounded-full"), "the soul renders the shared avatar primitive"
    assert_includes soul["style"].to_s, "#FB7185", "the soul avatar carries the soul's tint"
    mascot = frag.at_css(".hb-ava.hb-mascotava")
    assert mascot.at_css(".rounded-full"), "the base mascot renders the shared avatar primitive"
    assert_includes mascot["class"], "hb-submascot", "the mascot dims beneath a soul"
    # the names live in the side column: PRIMARY = the soul, SUB = the base mascot
    assert_equal "Avi", frag.at_css(".hb-names .hb-nameprimary").text, "the soul name is the primary, VISIBLE inline"
    assert_equal "Shellder", frag.at_css(".hb-names .hb-namesub").text, "the base mascot name stacks beneath as the sub name"
    # the soul avatar is emitted BEFORE the mascot avatar in the DOM (on top of the overlap)
    assert_operator html.index("agent-soul"), :<, html.index("hb-mascotava")
  end

  test "[unit] agent cell renders the base mascot as a SOLO stack (no soul, no sub name) when there is no acting soul" do
    html = heartbeat_agent_cell(mascot_slug: "sandshrew", pokemon: nil, agent_slug: nil)
    frag = Nokogiri::HTML::DocumentFragment.parse(html)

    stack = frag.at_css(".hb-agentstack[data-test=agent-stack]")
    assert stack, "a solo mascot still renders the stack wrapper"
    assert_includes stack["class"], "hb-solo", "a nil-soul cell is flagged solo"
    assert_nil frag.at_css(".hb-soulava"), "no acting-soul avatar in a solo cell"
    assert frag.at_css(".hb-ava.hb-mascotava .rounded-full"), "the lone mascot still renders its avatar"
    assert_equal "Sandshrew", frag.at_css(".hb-names .hb-nameprimary").text, "the solo mascot name is the primary"
    assert_nil frag.at_css(".hb-namesub"), "a solo cell has no subordinate name"
  end

  test "[unit] agent cell falls back to a titleized soul stand-in when the Agent is unseeded" do
    html = heartbeat_agent_cell(mascot_slug: "shellder", agent_slug: "carl", agent: nil)
    frag = Nokogiri::HTML::DocumentFragment.parse(html)
    soul = frag.at_css(".hb-soulava[data-soul=carl]")
    assert soul, "an unseeded soul still renders its avatar"
    assert soul.at_css(".rounded-full")
    assert_equal "Carl", frag.at_css(".hb-names .hb-nameprimary").text, "an unseeded soul still shows a titleized primary name"
  end

  test "[unit] agent cell renders an em dash when neither soul nor mascot is present" do
    html = heartbeat_agent_cell(mascot_slug: nil, agent_slug: nil)
    assert_includes html, "—"
    frag = Nokogiri::HTML::DocumentFragment.parse(html)
    assert_nil frag.at_css(".hb-agentstack"), "neither present renders no stack, just the meta dash"
    assert_nil frag.at_css(".hb-mascotava")
  end

  # Persisted so each action carries a real id — heartbeat_shared_turn_ids keys the
  # duplicate set by action.id (the flag the row partial checks).
  def turn_action(**attrs)
    AgentAction.create!({ session_id: "s", kind: "grep", outcome: "ok", actor: "agent",
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
