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

  test "[unit] the resume command runs from the folder decoded from the transcript path" do
    row = ->(path, sid = "f0f8b2e7-96a5-49d1") { SessionRoster::Row.new(session_id: sid, transcript_path: path) }
    base = "/Users/alex/.claude/projects"

    assert_equal "cd /Users/alex/projects && claude --resume f0f8b2e7-96a5-49d1",
                 row.call("#{base}/-Users-alex-projects/f0f8b2e7-96a5-49d1.jsonl").resume_command
    assert_equal "/Users/alex/projects/mcritchie-studio", row.call("#{base}/-Users-alex-projects-mcritchie-studio/x.jsonl").project_dir,
                 "a single dash stays: repo names hold dashes"
    assert_equal "/Users/alex/projects/mcritchie-studio/.worktrees/roster",
                 row.call("#{base}/-Users-alex-projects-mcritchie-studio--worktrees-roster/x.jsonl").project_dir, "'--name-' is '/.name/'"
    assert_equal "/Users/alex/projects/mcritchie-studio/.claude/worktrees/agent-x",
                 row.call("#{base}/-Users-alex-projects-mcritchie-studio--claude-worktrees-agent-x/x.jsonl").project_dir
    assert_equal "/Users/alex/projects", row.call("#{base}/-Users-alex-projects/f0f8/subagents/agent-a1.jsonl").project_dir,
                 "a subagent transcript resolves to its parent's folder"

    assert_nil row.call("#{base}/-Users-alex--agents-mailbox-avi/x.jsonl").resume_command, "outside ~/projects the decode is a guess"
    assert_nil row.call("/Users/alex/.codex/sessions/2026/rollout.jsonl").resume_command, "not a Claude Code transcript"
    assert_nil row.call(nil).resume_command
    assert_nil row.call("#{base}/-Users-alex-projects/x.jsonl", "a;rm -rf ~").resume_command, "an unsafe id never reaches the shell"
  end

  # [unit] WarmSession.project_dir is how Claude Code names a cwd's folder; decoding
  # its own output must give the cwd back, or `claude --resume` finds nothing.
  test "[unit] the decode round-trips Claude Code's own folder encoding" do
    require Rails.root.join("bin/lib/agent_warm_session").to_s
    home = "/Users/alex/.claude"
    ["/Users/alex/projects", "/Users/alex/projects/mcritchie-studio",
     "/Users/alex/projects/mcritchie-studio/.worktrees/session-roster-polish",
     "/Users/alex/projects/turf-monster/.claude/worktrees/agent-a1b2"].each do |cwd|
      path = File.join(AgentMailbox::WarmSession.project_dir(cwd, claude_home: home), "abc.jsonl")
      assert_equal cwd, SessionRoster::Row.new(session_id: "abc", transcript_path: path).project_dir, cwd
    end
    mailbox = File.join(AgentMailbox::WarmSession.project_dir("/Users/alex/.agents/mailbox-avi", claude_home: home), "abc.jsonl")
    assert_nil SessionRoster::Row.new(session_id: "abc", transcript_path: mailbox).resume_command,
               "a folder the decode cannot read renders no command, never a wrong one"
  end

  test "[unit] the roster runs a fixed number of queries however many activities a session has" do
    count = lambda do
      n = 0
      counter = ->(*, payload) { n += 1 unless payload[:name].in?(%w[SCHEMA TRANSACTION]) }
      ActiveSupport::Notifications.subscribed(counter, "sql.active_record") { SessionRoster.new(now: @now).rows }
      n
    end
    span("s-q", opened_at: @now - 1.day)
    one = count.call
    49.times { |i| span("s-q", opened_at: @now - 1.day + i.minutes, seq: i + 1) }
    assert_equal one, count.call, "no query per activity or per session (no N+1)"
    assert_equal 50, SessionRoster.new(now: @now).rows.first.activity_count
  end

  test "[unit] first and latest reason follow opened_at, then seq, per session" do
    span("s-a", opened_at: @now - 2.days, reason: "same instant later seq", seq: 2)
    span("s-a", opened_at: @now - 2.days, reason: "same instant first seq", seq: 1)
    span("s-a", opened_at: @now - 1.day, reason: "latest", seq: 0, path: "/Users/alex/.claude/projects/-Users-alex-projects/s-a.jsonl")
    span("s-b", opened_at: @now - 3.days, reason: "only one")

    by = SessionRoster.new(now: @now).rows.index_by(&:session_id)
    assert_equal ["same instant first seq", "latest"], [by["s-a"].first_reason, by["s-a"].last_reason]
    assert_equal ["only one", "only one"], [by["s-b"].first_reason, by["s-b"].last_reason]
    assert_equal "cd /Users/alex/projects && claude --resume s-a", by["s-a"].resume_command
  end
end
