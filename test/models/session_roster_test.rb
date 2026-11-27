require "test_helper"

# [unit] SessionRoster: one row per session from AgentActivity, SessionMascot and
# Task, with its ending. Wrapped means /wrap sealed a span with "session wrapped";
# the SessionEnd hook's "session ended" is not a wrap.
class SessionRosterTest < ActiveSupport::TestCase
  setup do
    @now = Time.zone.parse("2026-11-27 12:00")
  end

  def span(sid, opened_at:, reason: "work", outcome: nil, closed_at: nil, path: nil, seq: 0, mascot: nil)
    AgentActivity.create!(session_id: sid, category: "Explore", reason_slug: reason, opened_at: opened_at,
                          closed_at: closed_at, outcome_slug: outcome, transcript_path: path, seq: seq, mascot: mascot)
  end

  test "[unit] builds one row per session with its Pokémon, tasks and ending" do
    span("s-wrap", opened_at: @now - 3.days, reason: "build the roster", seq: 0)
    span("s-wrap", opened_at: @now - 2.days, reason: "ship it", outcome: "session wrapped",
                   closed_at: @now - 2.days + 1.hour, seq: 1)
    SessionMascot.create!(session_id: "s-wrap", mascot_slug: "pikachu")
    Task.create!(title: "Wrapped session task", stage: "shipped", session_id: "s-wrap")

    span("s-chase", opened_at: @now - 5.days, reason: "audit the board", outcome: "session ended",
                    closed_at: @now - 5.days + 1.hour)
    Task.create!(title: "Chase session open task", stage: "building", session_id: "s-chase")
    Task.create!(title: "Chase session done task", stage: "archived", session_id: "s-chase")

    span("s-quiet", opened_at: @now - 10.days, reason: "answer a question", closed_at: @now - 10.days)
    span("s-live", opened_at: @now - 30.minutes, reason: "still going", mascot: "eevee")
    span("s-mail", opened_at: @now - 1.day, path: "/Users/x/.claude/projects/-Users-x--agents-mailbox-alex/a.jsonl",
                   closed_at: @now - 1.day)
    span("s-old", opened_at: @now - 61.days, closed_at: @now - 61.days)

    roster = SessionRoster.new(now: @now)
    by = roster.rows.index_by(&:session_id)

    assert_equal %w[s-live s-mail s-wrap s-chase s-quiet], roster.rows.map(&:session_id), "newest activity first, the window drops s-old"

    wrap = by["s-wrap"]
    assert wrap.wrapped
    assert_equal "wrapped", wrap.ending(@now)
    assert_equal "pikachu", wrap.mascot_slug
    assert_equal "build the roster", wrap.first_reason
    assert_equal "ship it", wrap.last_reason
    assert_equal [1, 0], [wrap.task_count, wrap.open_task_count]

    chase = by["s-chase"]
    refute chase.wrapped, "the SessionEnd hook's 'session ended' is not a wrap"
    assert_equal "chase", chase.ending(@now)
    assert_equal [2, 1], [chase.task_count, chase.open_task_count]

    assert_equal "not_wrapped", by["s-quiet"].ending(@now)
    assert_equal "live", by["s-live"].ending(@now)
    assert_equal "eevee", by["s-live"].mascot_slug, "falls back to the activity's mascot"
    assert by["s-mail"].background

    assert_equal({ sessions: 4, wrapped: 1, not_wrapped: 2, chase: 1, live: 1, background: 1 }, roster.counts)
    assert_equal %w[s-chase s-quiet], roster.filtered(ending: "not_wrapped").map(&:session_id)
    assert_equal %w[s-chase], roster.filtered(ending: "chase").map(&:session_id)
    assert_equal %w[s-wrap], roster.filtered(ending: "wrapped").map(&:session_id)
    assert_includes roster.filtered(ending: "all", background: true).map(&:session_id), "s-mail"
    refute_includes roster.filtered(ending: "all").map(&:session_id), "s-mail"
  end

  test "[unit] an empty window yields no rows and zero counts" do
    roster = SessionRoster.new(now: @now)
    assert_empty roster.rows
    assert_equal 0, roster.counts[:sessions]
  end
end
