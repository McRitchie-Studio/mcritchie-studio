require "application_system_test_case"

# The admin login request, seen the way the operator sees it (task
# devops-admin-login-requests): the navbar notice on a page that is not the board,
# its click to /devops, the row's plain words, and the Approve tap granting so the
# asking harness collects at once.
#
# The 2026-11-10 defect this guards: the operator's Approve on /devops/tasks ran in
# the browser and the server recorded no decision, so the asking session polled
# 409 pending until the launch code granted it. Forgery protection is ON here, as
# in production (the test environment turns it off by default).
class AdminLoginNoticeSystemTest < ApplicationSystemTestCase
  setup do
    @forgery_was = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true
  end

  teardown do
    ActionController::Base.allow_forgery_protection = @forgery_was
  end

  test "[system] a pending admin-login request shows the navbar notice on a non-devops page, and its click opens /devops" do
    login = AgentLoginRequest.request!(soul: "steffon", harness_session_id: "system-harness")
    key = login.collect_key
    AgentActivity.open_activity!(session_id: "system-harness", category: "Edit",
                                 reason_slug: "Rotate the hub's Cloudflare token")

    visit triage_path
    notice = find("header [data-test='navbar-login-notice']")
    assert_equal "1", notice.find("[data-test='navbar-login-notice-count']").text
    notice.click

    assert_current_path deployments_path
    row = find("#admin-login-#{login.slug}")
    assert_selector "#admin-login-#{login.slug} [data-test='admin-login-who']", text: "Steffon, from harness session"
    assert_selector "#admin-login-#{login.slug} [data-test='admin-login-why']", text: "Rotate the hub's Cloudflare token"
    assert_selector "#admin-login-#{login.slug} [data-test='admin-login-grants']", text: "8-hour admin session as Steffon"
    assert_selector "#admin-login-#{login.slug} [data-test='admin-login-expires'] time"

    assert_raises(AgentLoginRequest::Refusal) { login.collect!(collect_key: key, harness_session_id: "system-harness") }

    row.find("[data-test='admin-login-approve']").click

    assert_text "Admin session granted to steffon"
    assert_no_selector "#admin-login-#{login.slug}"
    assert_no_selector "[data-test='navbar-login-notice']"
    assert_equal "granted", login.reload.status

    session = login.collect!(collect_key: key, harness_session_id: "system-harness")
    assert_equal "admin", session.tier
    assert_equal users(:alex).email, login.reload.decided_by
  end
end
