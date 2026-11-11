require "test_helper"

# [component] agent_login_requests/_pending: the row and its code render for an
# admin, and nothing renders for anyone else.
class AgentLoginPendingTest < ActionView::TestCase
  include StatusToneHelper
  include Studio::AtTimeHelper

  setup do
    @login = AgentLoginRequest.request!(soul: "mason", harness_session_id: "harness-one")
  end

  def render_for(admin)
    view.define_singleton_method(:admin?) { admin }
    render partial: "agent_login_requests/pending"
  end

  test "[component] an admin sees the request, its code and both taps" do
    render_for(true)

    assert_select "#admin-login-#{@login.slug}[data-soul='mason']" do
      assert_select "[data-test='admin-login-code']", text: @login.display_code
      assert_select "[data-test='admin-login-slug']", text: @login.slug
      assert_select "[data-test='admin-login-requested'] time[datetime]"
      assert_select "form[action='#{approve_agent_login_path(@login.slug)}'][method='post'] [data-test='admin-login-approve']"
      assert_select "form[action='#{refuse_agent_login_path(@login.slug)}'][method='post'] [data-test='admin-login-refuse']"
      assert_select "[onclick]", 0, "the taps are forms; an inline handler is what the enforcing CSP blocks"
    end
  end

  test "[component] the row says who asks, why, what Approve grants, and when it lapses" do
    AgentActivity.open_activity!(session_id: "harness-one", category: "Edit",
                                 reason_slug: "Rotate the R2 backup key", task_slug: nil)
    render_for(true)

    assert_select "#admin-login-#{@login.slug}" do
      assert_select "[data-test='admin-login-who']", text: /Mason, from harness session …ness-one/
      assert_select "[data-test='admin-login-why']", text: /Rotate the R2 backup key/
      assert_select "[data-test='admin-login-grants']", text: /8-hour admin session as Mason/
      assert_select "[data-test='admin-login-expires'] time[datetime='#{@login.window.ends_at.in_time_zone.iso8601}']"
    end
  end

  test "[component] a session with no narrated work says so instead of guessing why" do
    render_for(true)

    assert_select "#admin-login-#{@login.slug} [data-test='admin-login-why']", text: /narrated no work yet/
  end

  test "[component] a non-admin render carries no request and no code" do
    render_for(false)

    assert_not_includes rendered, @login.display_code
    assert_not_includes rendered, @login.slug
    assert_select "[data-test='admin-login-request']", 0
  end

  test "[component] a decided or lapsed request leaves the board" do
    @login.refuse!(by: "alex@test.com", reason: "declined by the operator")
    lapsing = AgentLoginRequest.request!(soul: "steffon", harness_session_id: "harness-two")

    travel 11.minutes do
      render_for(true)
      assert_select "[data-test='admin-login-request']", 0
      assert_not_includes rendered, lapsing.slug
    end
  end
end
