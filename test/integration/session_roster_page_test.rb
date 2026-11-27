require "test_helper"

# [integration] /devops/sessions is admin-only and draws one row per session with
# its ending pill, open-task count and the not-wrapped filter.
# [component] the roster table renders the ending pill, the open-task flag and the
# filter chips as plain ?ending= links.
class SessionRosterPageTest < ActionDispatch::IntegrationTest
  setup do
    AgentActivity.create!(session_id: "page-wrapped", category: "Explore", reason_slug: "wrapped work",
                          opened_at: 3.days.ago, closed_at: 3.days.ago + 1.hour, outcome_slug: "session wrapped")
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
