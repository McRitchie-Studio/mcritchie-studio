require "test_helper"

# [integration] /devops/sessions is admin-only and draws one row per session with
# its ending pill, open-task count and the not-wrapped filter.
# [component] the roster table renders the ending pill, the open-task flag and the
# filter chips as plain ?ending= links.
class SessionRosterPageTest < ActionDispatch::IntegrationTest
  setup do
    AgentActivity.create!(session_id: "page-wrapped", category: "Explore", reason_slug: "wrapped work",
                          opened_at: 3.days.ago, closed_at: 3.days.ago + 1.hour, outcome_slug: "session wrapped",
                          transcript_path: "/Users/alex/.claude/projects/-Users-alex-projects/page-wrapped.jsonl")
    AgentActivity.create!(session_id: "page-chase", category: "Explore", reason_slug: "unfinished work",
                          opened_at: 4.days.ago, closed_at: 4.days.ago + 1.hour, outcome_slug: "session ended")
    Task.create!(title: "Roster page open task", stage: "building", session_id: "page-chase")
  end

  test "[integration] signed out, /devops/sessions is behind the admin wall" do
    get session_roster_path
    assert_response :redirect
  end

  test "[integration] an admin sees every session with its ending" do
    log_in_as(users(:alex))
    get session_roster_path
    assert_response :success

    assert_select "[data-test='session-roster-row'][data-session='page-wrapped'][data-ending='wrapped']" do
      assert_select "[data-test='session-roster-ending']", text: /Wrapped/
    end
    assert_select "[data-test='session-roster-row'][data-session='page-chase'][data-ending='chase']" do
      assert_select "[data-test='session-roster-ending']", text: /Chase/
      assert_select "[data-test='session-roster-open']", text: "1"
      assert_select "a[href='/devops/tasks/#{Task.find_by(session_id: "page-chase").slug}']"
      assert_select "a[data-test='session-roster-heartbeat'][href*='session_id=page-chase']"
    end
    assert_select "a[data-test='board-link-sessions'][aria-current='page']"
  end

  test "[integration] each row carries its resume command and the empty background toggle hides" do
    log_in_as(users(:alex))
    get session_roster_path
    assert_select "[data-test='session-roster-row'][data-session='page-wrapped'] [data-test='session-roster-resume-copy']" \
                  "[data-copy-clip='cd /Users/alex/projects && claude --resume page-wrapped']",
                  text: "cd /Users/alex/projects && claude --resume page-wrapped"
    assert_select "[data-test='session-roster-row'][data-session='page-chase'] [data-test='session-roster-resume-copy']", 0,
                  "no transcript path, no guessed command"
    assert_select "[data-test='session-roster-background']", 0, "no background sessions, so no toggle"
  end

  test "[integration] a background session shows the toggle, and the toggle reveals it" do
    AgentActivity.create!(session_id: "page-mail", category: "Explore", reason_slug: "mailbox reply",
                          opened_at: 1.day.ago, closed_at: 1.day.ago + 1.minute,
                          transcript_path: "/Users/alex/.claude/projects/-Users-alex--agents-mailbox-avi/page-mail.jsonl")
    log_in_as(users(:alex))
    get session_roster_path
    assert_select "a[data-test='session-roster-background'][href='/devops/sessions?background=1']", text: "Show 1 background session"
    assert_select "[data-test='session-roster-row'][data-session='page-mail']", 0
    get session_roster_path(background: "1")
    assert_select "[data-test='session-roster-row'][data-session='page-mail'] [data-test='session-roster-resume-copy']", 0,
                  "a mailbox path outside ~/projects cannot be decoded, so no command"
  end

  test "[component] the table names Denver time, scrolls on a phone and labels the heartbeat link" do
    log_in_as(users(:alex))
    get session_roster_path
    assert_select "[data-test='session-roster-last-heading']", text: /Last \(MT\)/
    assert_select "table[data-test='session-roster-table'][class*='min-w-[72rem]']"
    assert_select "a[data-test='session-roster-heartbeat'][aria-label='Heartbeat for session page-cha']"
  end

  test "[component] the not-wrapped filter keeps only unwrapped sessions" do
    log_in_as(users(:alex))
    get session_roster_path(ending: "not_wrapped")
    assert_response :success

    assert_select "a[data-test='session-roster-filter'][data-ending='not_wrapped'][aria-current='page']"
    assert_select "a[data-test='session-roster-filter'][data-ending='chase'][href='/devops/sessions?ending=chase']"
    assert_select "[data-test='session-roster-row'][data-session='page-chase']"
    assert_select "[data-test='session-roster-row'][data-session='page-wrapped']", 0
  end

  test "[component] a filter nothing matches shows the empty state" do
    log_in_as(users(:alex))
    get session_roster_path(ending: "live")
    assert_select "[data-test='session-roster-empty']"
  end
end
