require "test_helper"

# [component] agent_login_requests/_pending: the row and its code render for an
# admin, and nothing renders for anyone else.
class AgentLoginPendingTest < ActionView::TestCase
  include StatusToneHelper

  setup do
    @login = AgentLoginRequest.request!(soul: "xan", harness_session_id: "harness-one")
  end

  def render_for(admin)
    view.define_singleton_method(:admin?) { admin }
    render partial: "agent_login_requests/pending"
  end

  test "[component] an admin sees the request, its code and both taps" do
    render_for(true)

    assert_select "#admin-login-#{@login.slug}[data-soul='xan']" do
      assert_select "[data-test='admin-login-code']", text: @login.display_code
      assert_select "[data-test='admin-login-approve'][data-url='#{approve_agent_login_path(@login.slug)}']"
      assert_select "[data-test='admin-login-refuse'][data-url='#{refuse_agent_login_path(@login.slug)}']"
    end
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
